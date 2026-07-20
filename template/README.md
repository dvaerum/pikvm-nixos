# My PiKVM

A PiKVM built on [pikvm-nixos](https://github.com/dvaerum/pikvm-nixos).

## Build the image

```sh
nix build .#nixosConfigurations.mykvm.config.system.build.sdImage
```

Flash `result/sd-image/*.img.zst` to an SD card (see the upstream README for
the `dd` command). The image boots on any supported Raspberry Pi (Pi 4, Pi
Zero 2 W, CM4) and auto-detects its hardware.

## Customize

Edit `flake.nix`:

- set your SSH key under `users.users.pikvm.openssh.authorizedKeys.keys`,
- point `services.pikvm.autoUpgrade.flake` at your own repo so devices
  self-update from it weekly,
- tweak kvmd via `services.pikvm.kvmd.settings`.

## Stay current

Bump the upstream base whenever you want:

```sh
nix flake update pikvm-nixos
```
