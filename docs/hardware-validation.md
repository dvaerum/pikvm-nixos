# Pi 4 hardware validation checklist

Everything below the software layer (services, config materialisation, the
`platform=auto` detector logic) is already exercised by the `kvmd-services`
NixOS VM test (`nix build .#checks.x86_64-linux.kvmd-services`). What a VM
**can't** cover — and what this checklist is for — is the Raspberry Pi
vendor-kernel boot, TC358743 CSI capture, real USB-OTG enumeration, and the
`config.txt` / device-tree layer. Flash a Pi 4, run these steps, and send the
captured output back so the ⚠️ items can be confirmed or fixed.

Related: [customizing.md](customizing.md) (options, install paths).

## 1. Flash + install

Direct-to-card install (formats **and** installs via disko; ⚠ erases the disk):

```sh
# From a checkout of this repo (or `github:dvaerum/pikvm-nixos#install-sd`):
nix run .#install-sd -- --board rpi4 /dev/sdX      # <-- the SD card / USB reader
```

**⚠ Add the vendor-kernel binary cache first**, or the install builds the
Raspberry Pi vendor kernel *from source* (hours, especially under emulation).
Either put it in `nix.conf`, or pass it inline on every build/install command:

```sh
nix run \
  --extra-substituters https://nixos-raspberrypi.cachix.org \
  --extra-trusted-public-keys nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI= \
  .#install-sd -- --board rpi4 /dev/sdX
```

Building the aarch64 system from an x86_64 host works via cross-build — enable
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` on the build host first
(the same cache flags apply, and turn the QEMU kernel compile into a download).

Before flashing, set your SSH key (the appliance is headless, key-only) in a
host file / downstream flake:
`users.users.pikvm.openssh.authorizedKeys.keys = [ "ssh-ed25519 …" ];`

## 2. First boot — capture the serial console

The config enables the UART (`enable_uart`, `disable-bt`). Capture the full
boot log over a 3.3 V USB-serial adapter on the GPIO header:

```sh
picocom -b 115200 /dev/ttyUSB0 | tee pi4-boot-serial.log
```

Watch for: firmware reading `config.txt`, the GIC armstub, `dwc2`/`cma`
overlays, and the kernel reaching a login prompt. **⚠ The `config.txt` / CMA /
device-tree layer is the least-tested part** — a boot hang here is the most
likely first failure.

Then SSH in: `ssh pikvm@<pi-ip>` (find the IP via your DHCP server / mDNS).

## 3. Service graph — should match the VM test, now on real silicon

```sh
systemctl status kvmd-platform-detect kvmd kvmd-media kvmd-otg --no-pager
```

Expected (all `active`; `kvmd-otg` is `active (exited)` — oneshot):

- `kvmd-platform-detect` → `active (exited)`
- `kvmd` / `kvmd-media` → `active (running)`
- `kvmd-otg` → `active (exited)` — **this is the first thing a VM can't verify**
  (a generic VM kernel lacks the vendor MSD configfs attrs, so the VM test only
  checks the config-path/libc bugs are gone; real bring-up happens here).

## 4. platform=auto picked the right profile

```sh
cat /run/kvmd/platform          # PIKVM_MODEL / PIKVM_VIDEO / PIKVM_BOARD
readlink -f /run/kvmd/main.yaml # the selected <base>-<video>-<board>.yaml
```

Expected on a Pi 4 with the official TC358743 CSI HAT:
`PIKVM_BOARD=rpi4`, `PIKVM_VIDEO=hdmi` (CSI). With a USB (UVC) grabber instead:
`PIKVM_VIDEO=hdmiusb`. **⚠ If it picked `hdmiusb` when you have a CSI HAT**, the
TC358743 didn't come up (see §5) — the detector greps
`/sys/class/video4linux/*/name` for `tc358743`.

## 5. Capture hardware (TC358743 CSI) — ⚠ core real-hardware gap

```sh
dmesg | grep -iE 'tc358743|cma|gpu_mem|dwc2'   # bring-up + errors
v4l2-ctl --list-devices                         # should list the tc358743
ls -l /dev/kvmd-video                           # udev symlink to the capture dev
v4l2-ctl -d /dev/kvmd-video --all | head -40    # formats / current signal
```

Feed HDMI into the capture input and confirm ustreamer sees a signal
(`journalctl -u kvmd | grep -i stream`). No signal / no `/dev/kvmd-video` ⇒ the
`dtoverlay=tc358743` wiring or CMA sizing needs tuning (see
`hosts/configtxt-pikvm.nix`, `hosts/rpi4.nix`).

## 6. USB-OTG + HID to a target machine — ⚠ real-hardware gap

Plug the Pi's USB-C/OTG port into a target PC. With `kvmd-otg` active the
target should enumerate an emulated **keyboard + mouse + mass-storage** device.

**HID device nodes** — the on-device proof of the `hidg*` → `/dev/kvmd-hid-*`
udev fix (PR #6). A VM can't check this, and without it OTG keyboard/mouse
*silently* don't work:

```sh
# on the Pi:
ls /sys/kernel/config/usb_gadget/kvmd/                     # the assembled gadget
ls -l /dev/kvmd-hid-keyboard /dev/kvmd-hid-mouse /dev/kvmd-hid-mouse-alt
#   ⚠ these MUST exist (udev symlinks to /dev/hidgN). If MISSING → the udev
#   rules regressed; report it. (`ls -l` shows they point at hidg0/1/2.)
```

**Functional verify — the real test.** It is not enough that `kvmd-otg` is
`active` and the nodes exist; confirm input actually *lands on the target*:

- On the **target**, open a text field (a terminal / editor) and focus it.
- From the PiKVM **web UI** (§7) or the API, type some keys and move the mouse.
- Watch the target: the characters should appear and the cursor should move.

No motion/keystrokes on the target despite `/dev/kvmd-hid-*` existing ⇒ a
gadget/HID-report issue to capture; missing nodes ⇒ the udev regression above.

## 7. nginx front-door + `/mcp` endpoint

The 443 nginx front-door landed (PR #6): it TLS-terminates (self-signed by
default) and reverse-proxies kvmd's API at `/api/` and — if enabled — the MCP
server at `/mcp`.

```sh
systemctl status nginx --no-pager                        # active
curl -sk https://localhost/api/auth/check                # 401 → kvmd reachable through the front-door
```

**MCP `/mcp` smoke** — only if `services.pikvm-mcp.enable = true` **and**
`services.pikvm.web.enable = true` (unified auth, `security = "kvmd"`):

```sh
systemctl status pikvm-mcp --no-pager                    # active, no onnxruntime dlopen error

# Log in with your REAL PiKVM credentials (curl -k for the self-signed cert):
curl -sk -u <pikvm-user>:<pass> \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -X POST https://localhost/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' -i | head
# → HTTP 200 + an `Mcp-Session-Id` header. No creds or WRONG creds → 401.
```

Same login as the PiKVM web UI (that's the point of unified auth). Full guide:
[mcp-endpoint.md](mcp-endpoint.md).

## 8. HID recovery (optional)

If the OTG HID ever stops registering on the target, the MCP server exposes a
`pikvm_hid_recover` tool (and, once the host helper is wired, an authenticated
loopback endpoint) that walks a recovery ladder — `soft_connect` (~6 s, the
proven fix) → `udc-rebind` → `reboot`. Rungs 2–3 are still **untested on real
hardware**: if you hit an HID drop, run the recovery and note **which rung**
restored input. Contract + ladder:
[pikvm_mcp_server hid-recovery runbook](https://github.com/dvaerum/pikvm_mcp_server/blob/main/docs/runbooks/hid-recovery.md).

## 9. Desktop target tuning (optional)

If you cable a **non-iPad HDMI** target in and want to measure/tune click
accuracy, run the MCP server's `benches/desktop-e2e.ts` (auto-calibrate →
absolute move/click → screenshot-verify); see its `desktop-workflow` skill.

## 10. What to send back

Bundle and return:

```sh
nixos-version; uname -a
journalctl -b -u kvmd-platform-detect -u kvmd -u kvmd-media -u kvmd-otg --no-pager
cat /run/kvmd/platform; readlink -f /run/kvmd/main.yaml
dmesg | grep -iE 'tc358743|cma|gpu_mem|dwc2|error|fail'
v4l2-ctl --list-devices; ls -l /dev/kvmd-video
```

Plus `pi4-boot-serial.log` from §2. That set is enough to confirm the boot/DT,
capture, and OTG layers — or to pinpoint exactly which ⚠ item to fix.
