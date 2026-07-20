# Customizing & making your own version

There are two supported ways to build on this project. Pick by how much you
want to change.

## Option A — a downstream flake (recommended for most)

Keep this repo as an upstream input and layer your changes on top. Nothing to
maintain except your own small flake.

```sh
nix flake init -t github:dvaerum/pikvm-nixos
```

Edit the generated `flake.nix` (hostname, SSH keys, kvmd settings, and — so
your devices self-update from *your* flake — `services.pikvm.autoUpgrade.flake`),
then build:

```sh
nix build .#nixosConfigurations.mykvm.config.system.build.sdImage
```

Everything you can set lives behind the module options:

| Option | Purpose |
|---|---|
| `services.pikvm.kvmd.platform` | `"auto"` (default) or a fixed `v2-hdmi-rpi4`-style profile |
| `services.pikvm.kvmd.settings` | Declarative kvmd override (the config tree), e.g. `{ kvmd.streamer.desired_fps.default = 30; }` |
| `services.pikvm.otg.enable` | USB HID/MSD gadget (on by default in the appliance) |
| `services.pikvm.autoUpgrade.{flake,dates,allowReboot,enable}` | Weekly self-update source & policy |

Update the base whenever you want: `nix flake update pikvm-nixos`.

## Option B — fork this repo

Fork when you want to change the internals (package a different kvmd version,
edit the universal `config.txt`, add a module, change defaults).

1. **Fork** `dvaerum/pikvm-nixos` on GitHub and clone your fork.
2. **Point self-updates at your fork.** Two references name the upstream repo;
   change both to your fork so flashed devices track *you*:
   - `hosts/universal.nix` → `services.pikvm.autoUpgrade.flake` (default
     `github:dvaerum/pikvm-nixos#universal`)
   - `modules/system/auto-upgrade.nix` → the `flake` option default
   (or just set `services.pikvm.autoUpgrade.flake` once in `hosts/universal.nix`.)
3. **Make your changes**, then build and flash:
   ```sh
   nix build .#nixosConfigurations.universal.config.system.build.sdImage
   ```
4. **Keep it current automatically.** The included
   `.github/workflows/update.yml` bumps nixpkgs weekly, builds to verify, and
   commits the new lock only if it works — and because devices self-update from
   your repo weekly, that verified bump rolls out to them on its own.

### Where things live

```
pkgs/        derivations (ustreamer, kvmd, luma-oled) — change versions/build here
modules/     services.pikvm.* options (kvmd, otg, auto-upgrade)
hosts/       common.nix (defaults), universal.nix (image + config.txt), appliance.nix
overlays/    exposes the pikvm.* package scope onto nixpkgs
template/    the scaffold used by Option A
```

## How the update chain works

```
you push to main ─▶ (weekly) update.yml bumps nixpkgs, builds, commits lock
                          │
                          ▼
   each device ─▶ (weekly) system.autoUpgrade rebuilds from the repo flake
```

So a change on `main` — yours or a verified nixpkgs bump — reaches every device
on its next weekly cycle. Set `services.pikvm.autoUpgrade.allowReboot = true`
if you want kernel/boot updates to activate without waiting for a manual reboot.

## Pinning a platform instead of auto-detect

The image auto-detects the board + capture device. To force a profile (e.g. on
hardware the detector guesses wrong), set:

```nix
services.pikvm.kvmd.platform = "v2-hdmi-rpi4"; # <base>-<video>-<board>
```

Valid values match the profiles under
`share/kvmd/configs.default/kvmd/main/*.yaml` in the kvmd package.
