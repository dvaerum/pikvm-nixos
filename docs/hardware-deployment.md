# Deploying pikvm-nixos onto real hardware

> **Status: PLAN — not yet executed.** pikvm-nixos has so far been verified
> **only in QEMU/NixOS VM tests. It has never booted on a real Raspberry Pi.**
> The first real boot is therefore its own validation milestone, done on a
> **spare** device — never on the live kiosk. See [§2](#2-non-destructive-rollout).
>
> **Target kiosk (`pikvm01`, 10.109.1.1): confirmed a DIY Raspberry Pi 4 Model B
> with a CSI TC358743 HDMI-capture board** — the flake's best-supported
> configuration (host attr `rpi4`). No Compute Module 4 work is needed; the
> CM4/other-board situation is kept in [Appendix A](#appendix-a-other-boards-cm4-pikvm-v3v4).
>
> A few specifics (the standalone image artifact and the capture/platform
> auto-detection behaviour) are pending confirmation from the aarch64-build node
> and are marked **_(pending build-node)_**.

## Hardware match

| What the kiosk is | What `rpi4` builds for | Verdict |
|---|---|---|
| Raspberry Pi **4 Model B** | `raspberry-pi-4.base` (Pi 4B, vendor kernel) | ✅ match |
| **CSI TC358743** HDMI capture | `tc358743` DT overlay + CSI config | ✅ match |
| USB-OTG to the target | `dwc2` peripheral mode | ✅ supported |

**Still to confirm from the user (secondary — don't block the build):**
- **PiKVM HAT?** OLED display / ATX power control / fan. We package `kvmd-oled`
  and ATX-over-GPIO, but they are **untested on real hardware** — if a HAT is
  present, they're part of the first-boot checklist; if not, they stay off.
- **Current boot medium + size** (SD card? USB SSD? capacity) — determines the
  spare medium to prepare.

---

## 1. Build the image and flash a spare medium

The installer wraps disko:

```sh
# On a build host, with the SPARE boot medium attached as /dev/sdX
nix run github:dvaerum/pikvm-nixos#install-sd -- --board rpi4 --disk /dev/sdX
#   → disko-install --flake .#rpi4 --disk main /dev/sdX
```

- Partitions the medium **GPT: a 1 GiB FAT firmware partition** (`/boot/firmware`
  — kernel, `config.txt`, overlays) **+ an ext4 root**, then installs the `rpi4`
  system onto it.
- Uses the **Raspberry Pi vendor kernel** (via nixos-raspberrypi) — required for
  TC358743 CSI capture and hardware H.264.
- The aarch64 image is **cross-built from x86_64** (binfmt/QEMU + the
  nixos-raspberrypi binary cache) or built natively on aarch64. Native builds +
  hardware-gap verification are routed to the Linux build node.
- Whether a standalone `dd`-able `sdImage`/`.img` is also produced (vs only the
  `disko-install`-onto-an-attached-disk path) is **_(pending build-node)_**.

**🖐 Physical hands (user task):** attach the spare medium to a machine with Nix
+ a card/USB reader and run the command, or receive a prepared medium.

## 2. Non-destructive rollout

The never-booted-on-hardware reality is de-risked by staging:

1. **First real boot on a SPARE Pi 4B / spare medium — not the live kiosk.**
   This is its own milestone: *"pikvm-nixos boots on real hardware for the first
   time."*
2. **Keep the kiosk's original Arch card untouched** — physically remove it and
   set it aside. Rollback = reinsert the Arch card and power-cycle. **Never
   blind-reflash the only unit.**
3. Only after full validation on the spare (§3) do we touch production.

## 3. First-boot + validation checklist (run on the spare)

Every item must pass before production. **🖐 = needs the user's spare Pi and eyes.**

- [ ] 🖐 Boots; serial/HDMI console captured for first-boot debugging
- [ ] SSH reachable
- [ ] `kvmd.service` active and **serving** (`/api/auth/check` answers)
- [ ] **CSI capture up** — the target's HDMI shows in kvmd. The **CMA / `gpu_mem`
      sizing and the `vc4-kms-v3d` interaction** are the parts most likely to
      need tuning (flagged in `hosts/configtxt-pikvm.nix`); the platform
      auto-detector should resolve the CSI capture profile at boot
      **_(pending build-node: exact auto-detect behaviour on real silicon)_**
- [ ] 🖐 **USB-OTG HID drives the iPad** — emit a move, confirm the cursor
      actually moves (flags lie; verify behaviourally)
- [ ] nginx **443** up; **/mcp** authenticates with a PiKVM login (only if the
      AI-agent stack is enabled — that's the separate held draft PR #17)
- [ ] **HID-recovery** works (`soft_connect` re-enumerates the UDC)
- [ ] 🖐 **OLED / ATX** if a PiKVM HAT is present
- [ ] All green → proceed to cutover

## 4. Config migration (stock Arch → pikvm-nixos)

- **kvmd users / htpasswd** — recreate with `kvmd-htpasswd` on the new image, or
  migrate `/etc/kvmd/htpasswd` verbatim (same `ldap_salted_sha512` scheme).
- **Network / hostname** — set `networking.hostName = "pikvm"` (or `pikvm01`) and
  the **static `10.109.1.1`** (confirm netmask/gateway/VLAN with the user) in the
  host config.
- **TLS cert** — the nginx front-door self-signs by default, or bring the
  existing cert via the BYO-cert path (`services.pikvm.mcpProxy.tls.certificate`
  / `.certificateKey` → a runtime secret).
- **MCP `passwordFile` secret** — user-provided; **sops-nix is not wired into the
  repo yet**, so at go-live either add sops-nix or materialise the file at the
  referenced runtime path. (Only relevant once the AI-agent stack, PR #17, is
  enabled.)

## 5. Production cutover

**🖐 All physical-hands, in a maintenance window:**

1. Confirm the spare passed the full §3 checklist.
2. Power down the kiosk; **remove and retain the Arch card** (rollback anchor).
3. Insert the validated pikvm-nixos medium; boot.
4. Re-run the §3 checklist on the production unit (network/target-specific items).
5. If anything fails → reinsert the Arch card, power-cycle (instant rollback),
   and report.
6. Only after the appliance is proven on hardware does the AI-agent `/mcp`
   enablement (held draft **PR #17**) get flipped, per its own go-live gates
   (user OK + `passwordFile` secret + MCP-pin bump).

## 6. Summary of hardware-gated user tasks

Nobody on the team has a Pi, so **every physical step is a user task**:

- Confirm the secondary hardware facts (HAT: OLED/ATX/fan; boot medium + size).
- Provide/attach a **spare** Pi 4B and spare boot medium.
- Flash the medium (run `install-sd`, or receive a prepared one).
- Boot the spare; **capture the serial/HDMI console**; report first-boot results
  — this *is* the validation.
- Perform the maintenance-window **swap + rollback**.

## Sequenced summary

1. User confirms secondary facts (HAT, boot medium) — build doesn't block on these.
2. Build the `rpi4` image; flash a **spare** SD.
3. **First-ever real boot** on the spare; run the §3 checklist; tune CMA/capture.
4. Migrate config (§4).
5. Production cutover (§5) in a maintenance window, Arch card retained for rollback.
6. Then (separately) flip the AI-agent `/mcp` stack (PR #17) per its own gates.

---

## Appendix A — other boards (CM4 / PiKVM v3/v4)

Kept for completeness; **not needed for the confirmed DIY Pi 4B kiosk.**

The flake targets **only** Pi 4 Model B (`rpi4`) and Pi Zero 2 W (`zero2w`) —
there is **no Compute Module 4 target.** PiKVM **v3 and v4 are CM4-based**, so a
v3/v4 unit could **not** be booted by the current images. Supporting one would be
net-new work:

- Add a CM4 host target (pending whether nixos-raspberrypi exposes a CM4 /
  compute-module module upstream).
- A different flash path: **CM4-eMMC requires `rpiboot`** (USB mass-storage mode)
  rather than an SD `dd`.
- Re-verify capture (v3/v4 use the same TC358743 CSI, so the capture config
  largely carries over) and the PiKVM HAT (OLED/ATX/fan).

kvmd's runtime detector recognises `Compute Module 4` and the HAT, but detection
is not a bootable image — the boot/firmware layer would still need the CM4 target.
