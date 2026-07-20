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
| `services.pikvm.kvmd.ipadCompat.enable` | iPadOS compatibility preset (see below) |
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

## Controlling an iPad (iPadOS compatibility)

Controlling an iPad over a USB HDMI grabber (e.g. the MacroSilicon MS2109)
needs a few HID/streamer adjustments. On Arch-PiKVM that's a whole checklist —
edit `override.yaml`, `sed`-patch `mouse.py`, add a pacman hook so the patch
survives upgrades, fiddle with USB ports. Here it's one option:

```nix
services.pikvm.kvmd.ipadCompat.enable = true;
```

That single switch, declaratively:

- **patches the absolute-mouse HID at build time** to advertise the boot mouse
  interface (`protocol=2`/`subclass=1`) — iPadOS ignores clicks otherwise. It's
  baked into the package, so it simply *can't* be lost on an upgrade (no
  re-apply hook needed).
- forces **relative mouse mode** and disables the secondary mouse (absolute
  reports read as touch/gestures on iPadOS),
- applies the tuned USB-capture streamer settings (`1280x720@30`, `--buffers=1`
  for low latency).

Your own `services.pikvm.kvmd.settings` still override any of these. The MS2109
grabber is matched by its USB id (`534d:2109`) for the `/dev/kvmd-video`
symlink, so — unlike upstream — it works in **any** USB port.

On the iPad itself: turn **AssistiveTouch off** (Settings → Accessibility →
Touch), and use Safari/Firefox for the web UI.

## MCP server ("give AI agents hands")

The image bundles the [PiKVM MCP server](https://github.com/dvaerum/pikvm_mcp_server)
— an MCP endpoint that lets an AI agent drive the target's keyboard/mouse/screen
(with vision-based mouse auto-calibration). It's **off by default**; enable it as
a hardened systemd service (`services.pikvm-mcp`), pointing it at the local kvmd:

```nix
services.pikvm-mcp = {
  enable = true;
  host = "https://127.0.0.1";          # the device's own kvmd
  passwordFile = "/run/secrets/pikvm-password";   # sops-nix / agenix / plain file
  # address = "0.0.0.0"; openFirewall = true;     # to reach it from a remote MCP client
};
```

Secrets are delivered via systemd `LoadCredential` (never in the Nix store or the
process environment). The server listens on port 3000 (`/mcp`). The package is
also available directly as `.#packages.<system>.pikvm-mcp-server`.

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
