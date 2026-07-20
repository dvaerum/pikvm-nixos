# pikvm-nixos

A declarative, flake-based **NixOS port of [PiKVM](https://pikvm.org/)** — the
open-source IP-KVM (KVM-over-IP) for Raspberry Pi. PiKVM is normally built on
Arch Linux ARM; this project rebuilds the same stack the Nix way: every
component is a proper derivation, every service a NixOS module, and each device
updates itself from this repository.

> **Status:** early scaffolding. The flake structure, self-updating image
> pipeline, and module layout are in place; the PiKVM packages (`ustreamer`,
> `kvmd`) and services are being ported in.

## What it gives you

- **A flashable SD-card image**, built entirely from the CLI.
- **Weekly self-updates**: each device tracks this flake on GitHub and rebuilds
  itself, so a `git push` to `main` rolls out to every KVM on its next cycle.
- **Idiomatic NixOS**: declarative options instead of imperative setup scripts.

## Layout

```
flake.nix              # entry point: packages, nixosModules, nixosConfigurations
overlays/              # the `pikvm` package scope, layered onto nixpkgs
pkgs/                  # PiKVM-specific derivations (ustreamer, kvmd, …)
modules/               # NixOS modules (services.pikvm.*)
  system/auto-upgrade.nix   # weekly self-referencing upgrade
hosts/                 # buildable device configs (pi4, …) + shared common.nix
```

## Build an image

```sh
# Build the SD image for the Pi 4 target (needs an aarch64-linux builder,
# native or remote; see the Nix manual on remote/cross builds).
nix build .#nixosConfigurations.pi4.config.system.build.sdImage

# Flash it (adjust /dev/sdX):
zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

On first boot the device comes up headless with SSH. Set your SSH keys and any
site config in `hosts/`, push, and it converges on the next weekly upgrade.

## License

See upstream PiKVM component licenses; this packaging is provided as-is.
