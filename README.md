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

## Use it in your own flake

This repo is meant to be built on. Fastest start — scaffold a downstream flake:

```sh
nix flake init -t github:dvaerum/pikvm-nixos
# edit flake.nix (hostname, SSH key, auto-upgrade source), then:
nix build .#nixosConfigurations.mykvm.config.system.build.sdImage
```

Or wire it in by hand:

```nix
{
  inputs.pikvm-nixos.url = "github:dvaerum/pikvm-nixos";
  outputs = { self, pikvm-nixos, ... }: {
    nixosConfigurations.mykvm = pikvm-nixos.inputs.nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        pikvm-nixos.nixosModules.appliance   # whole PiKVM system, override as needed
        { networking.hostName = "mykvm"; /* ... */ }
      ];
    };
  };
}
```

Exposed outputs:

| Output | What it is |
|---|---|
| `nixosModules.appliance` | The complete PiKVM system (universal image + services + defaults). Import and override. |
| `nixosModules.pikvm` (`.default`) | Just the `services.pikvm.*` options + package overlay, to compose your own system. |
| `overlays.default` | The `pikvm.*` packages (`ustreamer`, `kvmd`, …) layered onto nixpkgs. |
| `packages.<system>.{ustreamer,kvmd,…}` | The derivations directly. |
| `nixosConfigurations.universal` | The prebuilt universal image config. |
| `templates.default` | Scaffold for a downstream flake. |

Pin and bump the base on your own schedule with `nix flake update pikvm-nixos`.

## Documentation

- **[docs/customizing.md](docs/customizing.md)** — the full guide: layering a
  downstream flake vs. forking, every option, how the weekly update chain
  works, and pinning a platform. Start here to make your own modified version.

## License

See upstream PiKVM component licenses; this packaging is provided as-is.
