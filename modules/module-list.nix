# The actual PiKVM module graph — every module.services.pikvm.* option lives
# somewhere in this list. Deliberately separate from ./default.nix's
# nixpkgs.overlays: a VM test node that imports THIS file directly (to
# exercise the real module graph instead of a hand-copied subset) breaks if
# the overlay comes along too, because runNixOSTest supplies its own `pkgs`
# and nixpkgs's own read-only.nix throws "nixpkgs.overlays is defined
# multiple times ... set to read-only" the moment a second `nixpkgs.overlays`
# definition shows up — confirmed by a real eval during Round 2 planning.
# Keeping the overlay out of this file is what lets a test consume the real
# module list rather than drifting out of sync with it — the exact gap that
# caused Round 2's CI outage: 4 test files independently hand-copied their
# import lists and silently missed one when a module gained a new dependency.
{ ... }:
{
  imports = [
    ./mcp-integration.nix
    ./runtime-paths.nix
    ./deployment.nix
    ./system/auto-upgrade.nix
    ./otg.nix
    ./kvmd.nix
    ./hidmode.nix
    ./hidmode-endpoint.nix
    ./nginx.nix
    ./janus.nix
    ./hid-recovery.nix
    ./hid-recovery-endpoint.nix
    ./hid-latch-monitor.nix
    ./local-display.nix
    # ./webterm.nix is imported by ./nginx.nix (the web front-door owns it).
  ];
}
