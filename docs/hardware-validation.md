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

## 6. USB-OTG to a target machine — ⚠ real-hardware gap

Plug the Pi's USB-C/OTG port into a target PC. With `kvmd-otg` active the
target should enumerate an emulated **keyboard + mouse + mass-storage** device:

```sh
# on the Pi:
ls /sys/kernel/config/usb_gadget/kvmd/           # the assembled gadget
# on the target: it appears as a new USB HID + USB drive
```

Type via the web UI / API and confirm keystrokes land on the target.

## 7. MCP server (only if enabled)

Off by default. If `services.pikvm-mcp.enable = true`:

```sh
curl -sf http://127.0.0.1:3000/health            # secured:true
systemctl status pikvm-mcp --no-pager            # active, no onnxruntime dlopen error
```

(The booted-service + auth path is already VM-verified via
`checks.x86_64-linux.nixos-service` in the MCP repo.)

> Note: the browser web UI is fronted by nginx, which is a **separate module
> still being wired in** (`mcp-nginx-proxy`, in progress). Until it lands, kvmd
> serves its API on the local socket; verify via the service status / API
> rather than `https://<pi>/` in a browser.

## 8. What to send back

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
