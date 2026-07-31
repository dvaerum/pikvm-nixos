# Deploying pikvm-nixos onto real hardware

> **Status: PLAN — not yet executed.** pikvm-nixos has so far been verified
> **only in QEMU/NixOS VM tests. It has never booted on a real Raspberry Pi.**
> Several things that were *disabled or faked* in the VM tests run for the first
> time on metal (see [§4 first-boot risks](#4-first-boot-risks-never-validated-off-qemu)).
> So the first real boot is its own validation milestone, done on a **spare**
> device — never on the live kiosk.
>
> **Target kiosk (`pikvm01`, 10.109.1.1): confirmed a DIY Raspberry Pi 4 Model B
> with a CSI TC358743 HDMI-capture board** — the flake's best-supported
> configuration (host attr `rpi4`); no CM4 work needed (see
> [Appendix A](#appendix-a-other-boards-cm4--pikvm-v3v4)).

## Two blocking inputs before anything is built

1. **SSH key (🔴 build-time blocker).** `hosts/common.nix` ships
   `PasswordAuthentication = false` **and** an **empty** `authorizedKeys` for the
   `pikvm` user, with no console password. **Flashed as-is, the headless Pi is
   unreachable — no key, no password, no login.** A real SSH public key (or an
   initial password) **must be pre-seeded into the `rpi4` config before the image
   is built.** Both settings are `lib.mkDefault`, so a one-line host-file
   override fixes it. → **User input: whose SSH pubkey(s) go on `pikvm01`?**
2. **Board.** Already confirmed: DIY Pi 4B + CSI. ✅

Secondary (don't block the build): PiKVM HAT present? (OLED/ATX/fan); current
boot medium + size.

## OTG gadget bind (resolved 2026-07-31)

Earlier the USB OTG gadget assembly was aborting on a missing configfs attribute, so
the gadget never bound and keyboard/mouse/MSD were non-functional since first boot.
`kvmd-otg`'s `add_msd()` wrote
`…/functions/mass_storage.usb0/lun.0/inquiry_string_cdrom`, a PiKVM-kernel-patch
attribute the Pi vendor kernel (6.18.34) does **not** expose → `EACCES` aborted
assembly **before** the UDC bind, leaving the UDC empty and `/dev/kvmd-hid-*` missing.

**Fixed** by giving that write `optional=True` (`pkgs/kvmd`, the same pattern kvmd
already uses for other kernel-version-dependent attrs like `no_out_endpoint`) so
assembly skips the absent attribute and reaches the UDC bind. HW-confirmed on the real
appliance: `UDC=[fe980000.usb]` (was `[]`), `/dev/kvmd-hid-{keyboard,mouse,mouse-alt}`
present, `mass_storage` linked into config `c.1`, `kvmd-otg` genuinely active, zero
`Missing HID-*` errors, `mouse.outputs.available` `[]`→`[usb,usb_rel]`.

`keyboard.online`/`mouse.online` still read `false` on the uncabled bench: binding is
not enumeration — those flip `true` only once a **target host** enumerates the gadget
over the OTG cable. So HID and MSD end-to-end are validated at the OTG-target cabling
step, not on the bench.

## 1. Build the image and flash a spare medium

The `rpi4` config gives **two** ways to produce a flashable medium — both build
the vendor-kernel system (needed for TC358743 capture + HW H.264):

**(a) A standalone `dd`-able raw image — primary, simplest for the user.** `disko`
exposes `system.build.diskoImages` for `rpi4`, which builds a complete raw disk
image **without** an attached target disk; `dd` it (or use Raspberry Pi Imager) to
the card:

```sh
# On an aarch64 host (the build node); no target disk attached:
nix build github:dvaerum/pikvm-nixos#nixosConfigurations.rpi4.config.system.build.diskoImages
# → a raw .img → dd (or Raspberry Pi Imager) onto the SPARE card
```

**(b) `disko-install` straight onto an attached disk** (the `install-sd` app):

```sh
# On the build node, with the SPARE medium attached as /dev/sdX:
nix run github:dvaerum/pikvm-nixos#install-sd -- --board rpi4 --disk /dev/sdX
#   → disko-install --flake .#rpi4 --disk main /dev/sdX
```

- Both lay down **GPT: 1 GiB FAT firmware (`/boot/firmware`) + ext4 root** and
  install the `rpi4` vendor-kernel system.
- **Build natively on aarch64** (the build node's lane): the closure cross-builds
  from x86_64 under binfmt (CI does this), but an *emulated* full image build is
  multi-hour — native is practical. (`universal` also builds a `dd`-able
  `sdImage`, but it's the **mainline kernel with weaker CSI capture** — not the
  go-live path for this CSI kiosk.)
- ⚠️ **Boot-validation of the artifact is PENDING.** The image *builders* exist
  and eval, but the image has not yet been built + inspected to confirm the
  **FIRMWARE vfat partition is populated** with the RPi bootloader / u-boot /
  `config.txt` / DTBs / the `tc358743` overlay (not just the ext4 root). A
  dispatch-only CI job (`.github/workflows/validate-rpi4-image.yml`, on main)
  builds `diskoImages` (x86_64→aarch64 cross-build) and inspects exactly that —
  **fold the result in when it lands** ("artifact validated" vs the current
  "builder exists, boot-validation pending"). Path (a) is preferable to (b)
  precisely because it's a build-time artifact the build node can inspect offline
  before it ever touches hardware, whereas `disko-install`'s format/bootloader
  step is untested even in CI.

**🖐 Physical hands (user):** `dd` / Raspberry-Pi-Imager the built image onto the
spare card (or the build node hands over a prepared card).

## 2. Non-destructive rollout

1. **Image the stock Arch card first** (dd a full backup) — rollback anchor.
2. **First real boot on a SPARE Pi 4B / spare card — not the live kiosk.**
   Milestone: *"pikvm-nixos boots on real hardware for the first time."*
3. **Keep the kiosk's original Arch card untouched** — rollback = reinsert +
   power-cycle. **Never blind-reflash the only unit.**
4. Touch production only after the full §4 walk passes on the spare.

## 3. Config migration (stock Arch → pikvm-nixos)

- **SSH access** — see the blocker above; pre-seed the key at build time.
- **kvmd users / htpasswd** — recreate with `kvmd-htpasswd`, or migrate
  `/etc/kvmd/htpasswd` verbatim (same `ldap_salted_sha512` scheme).
- **Network / hostname** — `networking.hostName` + the static **`10.109.1.1`**
  (confirm netmask/gateway/VLAN) in the host config.
- **TLS cert** — self-signed by default, or BYO-cert
  (`services.pikvm.web.tls.*` → a runtime secret).
- **MCP `passwordFile`** — user-provided; **sops-nix not wired yet**. Only
  relevant once the AI-agent stack (held PR #17) is enabled.

## 4. First-boot risks (never validated off QEMU)

### Auto-detection vs explicit config

Platform **selection is automatic**: `services.pikvm.kvmd.platform = "auto"` runs
`kvmd-platform-detect.service` before kvmd, which detects the **board**
(device-tree model), the **base** (HAT EEPROM → defaults to `v2` when no HAT),
and the **capture** (scans for a `tc358743` v4l2 node → CSI, else USB). For the
DIY Pi 4B + CSI kiosk it should auto-resolve to profile **`v2-hdmi-rpi4` (CSI)**.

But the **firmware / device-tree layer is explicit** — baked into `hosts/rpi4.nix`
+ `configtxt-pikvm.nix` (vendor kernel, `tc358743` overlay, `gpu_mem=128`, `dwc2`
OTG) — **not** detected. Detection *depends on that being correct*:

> **⚠️ Silent USB fallback = a first-boot failure mode.** If the CSI driver
> doesn't load, the `tc358743` v4l2 node is absent, so the detector **silently**
> falls back to the USB / `v2-hdmi-rpi4` path → **no video, no error.** On first
> boot, explicitly confirm the detector selected the **CSI** profile (not the USB
> fallback) and that `/dev/video0` exists.

**First-boot tuning candidates:** CMA sizing + `vc4-kms-v3d` (flagged in
`configtxt-pikvm.nix`), `gpu_mem`, and **EDID** — the EDID comes from the packaged
profile and is *not* an exposed option, so a custom-EDID target is a **manual
step** if the captured resolution/modes are wrong.

### The risks

All apply directly to the Pi4B+CSI kiosk. Walk these on the spare — this **is**
the validation:

1. **⚠️ `atx=gpio` + `msd=otg` — THE BIG ONE.** `platform=auto` on a real Pi 4
   selects a profile that runs ATX-over-GPIO (opens `/dev/gpiochip0`) and
   MSD-over-OTG (writes the vendor-kernel cdrom `inquiry_string` configfs attr).
   **Both were disabled in *every* VM test** — the generic QEMU kernel
   crash-looped on them (the original U2 crash-loop). So first boot is the
   **first time atx/msd execute at all**; the exact things that crashed QEMU must
   now be proven on the vendor kernel + real GPIO/OTG. (On a DIY Pi with no ATX
   circuit, `atx=gpio` still opens `/dev/gpiochip0` but the power/reset controls
   are harmless no-ops — the concern is that it *initialises* without crashing.)
2. **TC358743 CSI capture** — the whole video path (DT-overlay → i2c bridge →
   `/dev/video0` → udev `kvmd-video` symlink → ustreamer). Zero QEMU coverage;
   **CMA/`gpu_mem` sizing + `vc4-kms-v3d`** are the top tuning suspects
   (`configtxt-pikvm.nix` self-flags both).
3. **HW H.264 via VideoCore** (`gpu_mem=128`) — no GPU in the VM; ustreamer's
   hardware encode path is unexercised.
4. **USB-OTG on real silicon** — `dwc2` binding the gadget to `fe980000.usb` (VM
   used `dummy_hcd`); the target actually enumerating the emulated kbd/mouse/MSD;
   and the `hidg0/1/2 → kvmd-hid-*` udev rules (a real-appliance bug we fixed)
   only ever fire on metal.
5. **HID-recovery on the REAL UDC** — `soft_connect`/`udc-rebind` against real
   `/sys/class/udc/fe980000.usb` (the VM's `dummy_hcd` state node lies
   "configured", so the CI 502 test hits the write-error branch, not a real
   timeout). Real idle-drop (~6 s) vs dead-after-reboot timing only exists on hw.
6. **Platform detector** (`modules/kvmd.nix`, self-labeled "expected to be tuned
   on real hardware") — parses `/proc/device-tree/model` + HAT EEPROM + the
   TC358743 v4l2 name, falls back to `v2-hdmi-rpi4`. Never run against a real
   device-tree; on a DIY Pi 4 (no HAT EEPROM) it should land on v2 + `video=hdmi`
   iff the TC358743 is detected — **confirm the selected profile on first boot.**
7. **Vendor-kernel boot chain** (u-boot + armstub8-gic → kernel) + the untested
   `disko-install` format/bootloader-write — first real exercise is the spare card.
8. **OLED/ATX HAT** — `luma-oled` packaged but unwired/untested; a DIY build may
   not have the HAT. Low priority.

## 5. Production cutover

**🖐 Physical, in a maintenance window:**

1. Confirm the spare passed the full §4 walk.
2. Power down the kiosk; **remove and retain the Arch card** (rollback anchor).
3. Insert the validated pikvm-nixos card; boot; re-walk network/target-specific
   items.
4. On any failure → reinsert Arch card, power-cycle (instant rollback), report.
5. Only after the appliance is proven on hardware does the AI-agent `/mcp` stack
   get flipped, per its own go-live gates.
6. **Drop the stock-box HID-recovery SSH bridge (least-privilege).** *Until*
   cutover, `pikvm01` runs stock Arch and the **off-box** MCP (on georg's Mac,
   `macos-nixos-setup`) self-recovers HID via a **root-SSH transport**
   (`PIKVM_HID_RECOVERY_SSH=root@pikvm01.bb.vcamp.dk`) — a bridge, validated live
   2026-07-30. The appliance ships the loopback HID-recovery endpoint **default-on**
   (`services.pikvm.hidRecovery.endpoint` follows `services.pikvm-mcp.enable`), and
   the MCP tool **prefers the HTTP endpoint when `PIKVM_HID_RECOVERY_URL` is set**.
   So once `pikvm01` *is* the appliance: wire the off-box MCP at the appliance's
   endpoint — **Option 2**: front it on the nginx **443** vhost with the bearer
   token (the MCP is off-box, so *not* bare `loopback:8082` exposed on the LAN) —
   and **remove the root-SSH grant + `PIKVM_HID_RECOVERY_SSH`** from the mac
   wrapper, so the privileged SSH path doesn't outlive its need.

## 6. Who does what

- **Build node (`@nixos-developer-system`):** native aarch64 `rpi4` build +
  `disko-install` to the card + owns the first-boot checklist. Wires the SSH-key
  pre-seed once the key is known.
- **This node (`@georgs-mac-mini`, NixOS/hosts/CI):** the host config, the
  install-sd/disko path, docs, PR/merge. **No Pi/device access.**
- **🖐 The user:** supplies the SSH key + a **spare Pi 4B + card**; physically
  boots the spare and **captures the serial/HDMI console**; walks §4 and reports
  (nobody on the team has a Pi); performs the maintenance-window swap + rollback.
  Note: the live kiosk is currently driven (for iPad work) via its stock PiKVM —
  that unit must **not** be reflashed until the spare is proven.

## Sequenced summary

1. **User provides the SSH pubkey** (blocker) + secondary facts.
2. Pre-seed the key into `rpi4`; **native-build** the image on the build node.
3. Backup the Arch card; **disko-install to a SPARE card**.
4. **First-ever real boot** on the spare; walk §4 (atx/msd + capture first); tune.
5. Migrate config (§3).
6. Production cutover (§5), Arch card retained for rollback.
7. Then (separately) the AI-agent `/mcp` stack (PR #17) per its own gates.

---

## Appendix A — other boards (CM4 / PiKVM v3/v4)

Not needed for the confirmed DIY Pi 4B kiosk; kept for completeness.

The flake targets only Pi 4 Model B (`rpi4`) and Pi Zero 2 W (`zero2w`) — **no
Compute Module 4 target.** PiKVM v3/v4 are CM4-based, so they can't boot the
current images. A CM4 target is **feasible** (CM4 is bcm2711 / Pi-4 family; the
`bcm2711-rpi-cm4*.dtb` device trees already ship in `raspberrypifw` and the
`universal` image copies them) — assemble `hosts/cm4.nix` from
`raspberry-pi-4.base` + the CM4 DTB + the `[cm4]` `config.txt` block
(`tc358743-audio`, `dtparam=i2c_arm=on` — present in `universal`, absent from the
vendor `rpi4`), **pending confirmation of whether nixos-raspberrypi ships a CM4
base** (build node to verify only if a CM4 unit ever appears). CM4-eMMC also needs
the `rpiboot` flash path rather than an SD `dd`.
