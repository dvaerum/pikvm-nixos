# Running CI locally

Every CI job in this repo is just a `nix` command. You can reproduce the whole
pipeline on any Linux box with Nix — no GitHub Actions, no minutes, no waiting on
a runner. This is the authoritative local mirror of `.github/workflows/ci.yml`
(+ `image.yml`); if CI is red (or GitHub Actions is unavailable), run the matching
command here and read the same build log.

The commands below are transcribed **verbatim** from the CI workflows, so they
are exactly what CI runs — nothing paraphrased from memory. The VM-test path
(`checks.x86_64-linux.ci-vm-gate`) has been executed end-to-end on the Linux
build host; the rest are the same `nix build`/`nix eval` invocations against the
same flake attributes CI targets.

---

## 1. Prerequisites

These are what actually bite — get them right once and every command below works.

### Nix with flakes
```sh
nix --version                      # 2.18+ recommended
# Ensure flakes are on. Either in /etc/nix/nix.conf (or ~/.config/nix/nix.conf):
#   experimental-features = nix-command flakes
# or pass --extra-experimental-features "nix-command flakes" per command.
```

### `/dev/kvm` — required for the VM tests (`checks.*`)
`nixosTest`/`runNixOSTest` boots a real VM under QEMU/KVM.
```sh
test -e /dev/kvm && echo "kvm ok" || echo "NO /dev/kvm — VM tests will fail/slow"
# You must be able to read+write it (usually: be in the 'kvm' group).
ls -l /dev/kvm
```
If you're on an x86_64 host the `checks.x86_64-linux.*` tests run **natively**
(fast). No KVM ⇒ QEMU falls back to slow TCG emulation or the test fails.

### binfmt/QEMU for aarch64 — required for the cross (Pi) builds
The `build-packages` job builds `aarch64-linux` derivations on an x86_64 host via
emulation. Nix needs `aarch64-linux` as an extra platform **and** a registered
binfmt handler.
```sh
nix show-config | grep -E '^(system|extra-platforms)'   # want aarch64-linux listed
test -e /proc/sys/fs/binfmt_misc/aarch64 || echo "register a qemu-aarch64 binfmt handler"
```
- **NixOS:** `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` (this also adds
  `extra-platforms = aarch64-linux`). Rebuild.
- **Other distros:** `nix.settings.extra-platforms = aarch64-linux` in nix.conf,
  plus register qemu-user, e.g. `docker run --privileged --rm tonistiigi/binfmt --install arm64`.

### ⚠️ nixos-raspberrypi.cachix.org — THE one that bites
The Pi targets use the **Raspberry Pi vendor kernel** (`linux_rpi-bcm2711`). It is
**not** on `cache.nixos.org`, so without this substituter Nix will **compile the
kernel from source** — and under aarch64 emulation that's *hours*. (This is exactly
what stalled the first local image-build attempt: ~312 derivations to build incl.
the kernel; with the cache it's ~90 and the kernel is *fetched*.)

Add the substituter as a **trusted** one (untrusted flake/CLI substituters are
silently ignored — you'll see `ignoring untrusted flake configuration setting
'extra-substituters'`):

- **NixOS** (`configuration.nix`, then rebuild):
  ```nix
  nix.settings = {
    trusted-users = [ "root" "@wheel" ];   # your user must be trusted
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };
  ```
- **Other distros** — add to `/etc/nix/nix.conf` and `sudo systemctl restart nix-daemon`:
  ```
  extra-substituters = https://nixos-raspberrypi.cachix.org
  extra-trusted-public-keys = nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=
  ```
- **Per-command** (only works if you're already a `trusted-user`):
  ```sh
  nix build … \
    --option extra-substituters https://nixos-raspberrypi.cachix.org \
    --option extra-trusted-public-keys nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=
  ```
Check you're trusted: `nix show-config | grep trusted-users` (must list your user
or a group you're in).

### Disk space
VM tests and especially the Pi image are multi-GB. Keep **≥ 20 GB** free on the
Nix store (`df -h /nix`). The SD image / disko raw is ~2 GB on top of the closure.
`nix-collect-garbage -d` if you're tight.

---

## 2. Per-job commands

Run from the repo root. Add `--print-build-logs` (shown) to stream the build log.

### CI job `eval` — "Evaluate flake"
```sh
nix flake check --all-systems --no-build
nix eval --raw .#nixosConfigurations.universal.config.system.build.toplevel.drvPath
```
Pure evaluation (no builds): catches config/module/type errors across all systems.
Fast; needs no KVM/binfmt/cachix.

### CI job `build-packages` — "Build packages (aarch64 via emulation)"
Needs binfmt aarch64 **and** the cachix substituter (§1).
```sh
nix build --print-build-logs .#packages.aarch64-linux.ustreamer
nix build --print-build-logs .#packages.aarch64-linux.kvmd
nix build --print-build-logs \
  .#nixosConfigurations.rpi4.config.system.build.toplevel \
  .#nixosConfigurations.zero2w.config.system.build.toplevel
nix build --print-build-logs .#packages.x86_64-linux.pikvm-mcp-server
```
The vendor kernels for the rpi4/zero2w toplevels come from the cachix cache — if
you see the kernel *building*, your substituter isn't trusted (§1).

### CI job `vm-test` — "NixOS VM tests (ci-vm-gate)"
Needs `/dev/kvm` (§1). `ci-vm-gate` is a `linkFarm` bundling every VM test with
hardware-confirmed regression history (see `flake.nix`'s `ciVmGateNames` for the
current list + rationale) — building it builds and boots all of them; a green
build == all of them passing.
```sh
nix build --print-build-logs .#checks.x86_64-linux.ci-vm-gate
```
Debugging a single check within the gate (swap in the attr name from
`ciVmGateNames`):
```sh
nix build --print-build-logs .#checks.x86_64-linux.hid-recovery
```
Reading results / logs:
```sh
# The interactive test driver (step through / poke the VM) for any check:
nix build .#checks.x86_64-linux.hid-recovery.driverInteractive && ./result/bin/nixos-test-driver
# Re-run and keep the full log even on success:
nix build --print-build-logs -L .#checks.x86_64-linux.ci-vm-gate
```
Long runs: detach so a dropped shell doesn't kill the build —
`setsid nix build … .#checks.x86_64-linux.ci-vm-gate > gate.log 2>&1 &` then
`tail -f gate.log`.

---

## 3. The flash image (workflow `image.yml` + `validate-rpi4-image.yml`)

### `universal` SD image — dd-able `.img` (mainline kernel)
This is what `image.yml` builds. Uses the mainline nixpkgs kernel (on
`cache.nixos.org`), so it does **not** need the cachix substituter — only binfmt.
```sh
nix build --print-build-logs .#nixosConfigurations.universal.config.system.build.sdImage
ls result/sd-image/*.img*        # zstd-compressed image, ready to dd
```

### rpi4 vendor-kernel flash (the real appliance target)
Two paths, both cross-built from x86_64 (see the deployment doc):

- **Onto a real card** — the supported path (`nix run .#install-sd`):
  ```sh
  nix run .#install-sd -- --board rpi4 /dev/sdX      # ERASES /dev/sdX
  ```
- **Into a raw image, then inspect** — no card needed; this is what the
  `validate-rpi4-image` workflow does (loop-mount + `disko-install`). See that
  workflow for the exact `truncate → losetup → nix run .#install-sd -- --board
  rpi4 <loop> → mount + inspect` recipe.

⚠️ **`diskoImages` caveat.** There is a raw-image builder
`.#nixosConfigurations.rpi4.config.system.build.diskoImages`, but it assembles the
image inside a QEMU VM using **virtiofsd**, which **fails inside the Nix build
sandbox** (`mount ID (0) does not match expected value` → I/O error → the image
build aborts). This is a sandbox/infra limitation, not a flake defect — the full
system builds fine and disko begins formatting a 2 GiB raw before the VM step dies
(observed in CI run `30260168293`). Use the **`install-sd` / loop-mount
disko-install** path above instead; it needs no VM/virtiofsd.

---

## 4. Run everything

A single script that runs the whole `ci.yml` pipeline and stops on the first
failure. Assumes §1 is satisfied (KVM + binfmt + cachix).
```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "== eval =="
nix flake check --all-systems --no-build
nix eval --raw .#nixosConfigurations.universal.config.system.build.toplevel.drvPath >/dev/null

echo "== build-packages (aarch64 via emulation) =="
nix build --print-build-logs \
  .#packages.aarch64-linux.ustreamer \
  .#packages.aarch64-linux.kvmd \
  .#nixosConfigurations.rpi4.config.system.build.toplevel \
  .#nixosConfigurations.zero2w.config.system.build.toplevel \
  .#packages.x86_64-linux.pikvm-mcp-server

echo "== vm-test (needs /dev/kvm) =="
nix build --print-build-logs .#checks.x86_64-linux.ci-vm-gate

echo "ALL CI JOBS PASSED LOCALLY"
```
Tip: `nix flake check` alone (no `--no-build`) builds **all** checks for the host
system in one go — a quick "is the VM suite green?" without listing each attr.

---

## 5. What you CANNOT reproduce locally

CI is a full mirror of the *buildable* surface, but some things are only real on
hardware nobody on the team has — these are **user tasks on a real Pi**, not CI:

- Booting the vendor kernel on a real Pi 4 (u-boot/armstub → kernel handoff).
- TC358743 CSI capture, hardware H.264 (VideoCore), and the platform auto-detector
  against a real device-tree/HAT.
- USB-OTG to a target machine (dwc2 on real silicon; the `hidg*→kvmd-hid-*` udev
  rules; `atx=gpio`/`msd=otg`, which are disabled in the VM tests).
- `install-sd` onto a physical SD card + first boot.

See `docs/hardware-deployment.md` for the first-boot validation checklist covering
these.
