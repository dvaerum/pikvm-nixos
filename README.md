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

## Targets

Two vendor-kernel targets (Raspberry Pi vendor kernel, needed for TC358743 CSI
capture + hardware H.264), plus a mainline single-image fallback:

| Attribute | Board / role | Notes |
|---|---|---|
| `rpi4` | Raspberry Pi 4 | **required target**, vendor kernel, stock desktop/absolute defaults |
| `pikvm01` | Raspberry Pi 4 (deployment of `rpi4`) | permanently-cabled iPad kiosk, TEST rig — not production |
| `it-03400` | Raspberry Pi 4 (deployment of `rpi4`) | intermittently-cabled hardware-verification appliance |
| `zero2w` | Raspberry Pi Zero 2 W | bonus target, vendor kernel |
| `universal` | any (Pi 4 + Zero 2 W + CM4) | mainline kernel; single `.img` file, weaker capture |

## Install straight to an SD card

The simplest path — format **and** install in one command (via
[disko](https://github.com/nix-community/disko)):

```sh
nix run .#install-sd -- --board rpi4 /dev/diskX     # ⚠ erases /dev/diskX
# or: --board pikvm01 | it-03400 | zero2w
```

Building the aarch64 system from an x86_64 host works too (cross-build); enable
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` on the build host.

### Or build an image file

```sh
# Mainline single image that boots any supported board:
nix build .#nixosConfigurations.universal.config.system.build.sdImage
zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

On first boot the device comes up headless with SSH and auto-detects its
capture hardware. Set your SSH keys / site config in `hosts/`, push, and it
converges on the next weekly upgrade.

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
- **[docs/hardware-validation.md](docs/hardware-validation.md)** — flash a Pi 4
  and run the checklist: the boot/device-tree, TC358743 capture, and USB-OTG
  layers a VM can't cover, plus exactly what to capture and send back.
- **[docs/mcp-endpoint.md](docs/mcp-endpoint.md)** — expose the PiKVM MCP server
  at `https://<pikvm>/mcp` so an AI agent can drive the KVM, with unified auth
  (the same login as the web UI) and a bring-your-own-cert option.

## License

See upstream PiKVM component licenses; this packaging is provided as-is.
