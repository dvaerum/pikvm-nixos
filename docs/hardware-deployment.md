# Deploying pikvm-nixos onto real hardware

> **Status: PLAN — not yet executed.** pikvm-nixos has so far been verified
> **only in QEMU/NixOS VM tests. It has never booted on a real Raspberry Pi.**
> The first real boot is therefore its own validation milestone, and it must be
> done on a **spare** device, never on the live kiosk. See
> [§3 Non-destructive rollout](#3-non-destructive-rollout).
>
> Some facts below (the standalone image artifact, CM4 upstream support, and the
> first-boot risk list) are pending confirmation from the aarch64-build node and
> are marked **_(v2-pending)_**.

## 0. The make-or-break: which board is the kiosk?

Everything forks on one fact. The flake builds bootable images for **exactly two
boards**:

| Host attr | Board | nixos-raspberrypi module |
|-----------|-------|--------------------------|
| `rpi4`   | Raspberry Pi **4 Model B** | `raspberry-pi-4.base` |
| `zero2w` | Raspberry Pi **Zero 2 W**  | `raspberry-pi-02.base` |

There is **no Compute Module 4 (CM4) target.** But **PiKVM v3 and v4 are
CM4-based.** So:

- **DIY PiKVM on a Pi 4 Model B → in range** (the `rpi4` image is built for it).
- **PiKVM v3 / v4 (CM4) → we cannot boot it today.** No CM4 boot config exists,
  and CM4-with-eMMC uses an entirely different flash path (`rpiboot` USB mass-
  storage mode, not an SD `dd`). Supporting it is **net-new build work**
  (add a CM4 host target — pending whether nixos-raspberrypi supports CM4
  upstream, _(v2-pending)_) that must land **before anything is flashable.**

kvmd's runtime platform detector *does* recognise `Compute Module 4` and the
PiKVM HAT — but **detection is not a bootable image.** The boot/firmware layer
only has Pi 4B and Zero 2 W.

**→ Blocking input #1 (from the user): the exact kiosk hardware (§2).**

## 1. What the flake produces, and the build → flash steps

The installer app wraps disko:

```sh
# On a build host, with the target boot medium attached as /dev/sdX
nix run github:dvaerum/pikvm-nixos#install-sd -- --board rpi4 --disk /dev/sdX
# → disko-install --flake .#rpi4 --disk main /dev/sdX
```

This partitions the medium **GPT: a 1 GiB FAT firmware partition** (kernel,
`config.txt`, overlays, at `/boot/firmware`) **+ an ext4 root**, then installs
the `rpi4` system onto it. The image uses the **Raspberry Pi vendor kernel**
(via nixos-raspberrypi) — required for TC358743 CSI capture and hardware H.264.

- It installs onto a **disk you attach to the build host** (an SD/USB reader),
  not a `dd`-able `.img` by default. Whether a standalone `sdImage`/`.img`
  artifact is also available is **_(v2-pending)_** with the build node.
- Building the aarch64 image is cross-compiled from x86_64 (binfmt/QEMU + the
  nixos-raspberrypi binary cache) or built natively on aarch64. Native builds +
  VM/hardware-gap verification are routed to the Linux build node.
- **Replacing stock Arch = reflashing the boot medium.** This is only
  non-destructive if done on a **spare** medium (§3).

## 2. Hardware facts we must get from the user

These gate the entire plan. Please confirm:

| # | Question | Why it matters |
|---|----------|----------------|
| a | PiKVM model: **v3 / v4 Mini / v4 Plus / DIY v2 / other?** | Identifies the board class |
| b | SBC: **Pi 4 Model B** or **Compute Module 4?** | Decides whether a bootable image even exists |
| c | If CM4: **eMMC (onboard)** or **Lite (SD)?** | eMMC ⇒ `rpiboot` flash path, much fiddlier |
| d | HDMI capture: **CSI ribbon (TC358743)** or **USB dongle?** | Our image configures TC358743 CSI; USB capture needs a different platform |
| e | **PiKVM HAT** present? (OLED, ATX power, fan) | We package `kvmd-oled` + ATX/GPIO, but they're **HW-untested** |
| f | Boot medium + size (SD / USB-SSD / eMMC) | Determines the flash procedure |

**What our image supports today:** Pi 4 Model B + TC358743 CSI capture +
`dwc2` peripheral-mode USB-OTG + OLED/ATX (untested on real silicon).
**Best-case match = a DIY PiKVM on a Pi 4 Model B with a CSI TC358743 capture
board.**

## 3. Non-destructive rollout

The never-booted-on-hardware reality is de-risked by staging:

1. **First real boot on a SPARE Pi / spare boot medium — not the live kiosk.**
   This is its own milestone: *"pikvm-nixos boots on real hardware for the first
   time."*
2. **Preserve the kiosk's original Arch storage untouched** — physically remove
   the Arch SD/SSD and set it aside. Rollback = reinsert the original medium and
   power-cycle. **Never blind-reflash the only unit.**
3. Only after full validation on the spare (§5) do we touch production.

## 4. Config migration (stock Arch → pikvm-nixos)

- **kvmd users / htpasswd** — recreate with `kvmd-htpasswd` on the new image, or
  migrate `/etc/kvmd/htpasswd` verbatim (same `ldap_salted_sha512` scheme).
- **Network / hostname** — set `networking.hostName` (currently `pikvm`) and the
  static address (confirm `10.109.1.1` + any VLAN) in the host config.
- **TLS cert** — the nginx front-door self-signs by default; or bring the
  existing cert via the BYO-cert path (`services.pikvm.mcpProxy.tls.certificate`
  / `.certificateKey` → a runtime secret).
- **MCP `passwordFile` secret** — user-provided; **sops-nix is not wired into
  the repo yet**, so at go-live either add sops-nix or materialise the file at
  the referenced runtime path.

## 5. Cutover + real-hardware validation checklist

Run **on the spare first**; every item must pass before production:

- [ ] Boots; SSH reachable
- [ ] `kvmd.service` active and **serving** (`/api/auth/check` answers)
- [ ] **HDMI capture** shows the target — the CMA / `gpu_mem` sizing and the
      `vc4-kms-v3d` interaction are the parts most likely to need tuning
      (flagged in `hosts/configtxt-pikvm.nix`) _(v2-pending: build-node risk list)_
- [ ] **USB-OTG HID drives the iPad** — emit a move, cursor actually moves
      (flags lie; verify behaviourally)
- [ ] nginx **443** up; **/mcp** authenticates with a PiKVM login (unified auth)
- [ ] **HID-recovery** works (`soft_connect` re-enumerates the UDC)
- [ ] OLED / ATX if a HAT is present
- [ ] Only then: swap into production in a **maintenance window**, Arch medium
      retained for instant rollback

## 6. Hardware-gated tasks (require physical hands — nobody on the team has a Pi)

These are **user tasks**:

- Confirm the exact hardware (§2) — **blocks the plan.**
- Provide/attach the **spare** Pi or spare boot medium.
- Physically **flash** the medium (run `install-sd` against the reader; `rpiboot`
  if CM4-eMMC).
- Insert, boot, and **capture the serial/HDMI console** for first-boot
  debugging — this *is* the validation.
- Perform the physical **swap + rollback** in the maintenance window.

## Sequenced summary

1. **User confirms the board (§2).** ← blocking
2. **If CM4:** first work item is *scope + build a CM4 host target and the
   `rpiboot` flash path* (with the build node) before anything is flashable.
   **If DIY Pi 4B:** proceed to the spare-device validation path.
3. Build the image; flash a **spare** medium.
4. First-ever real boot on the spare; run the §5 checklist; tune (CMA/capture).
5. Migrate config (§4).
6. Production cutover in a maintenance window, Arch retained for rollback.
7. Only after the appliance is proven on hardware does the AI-agent `/mcp`
   enablement (held draft PR #17) get flipped, per its own go-live gates.
