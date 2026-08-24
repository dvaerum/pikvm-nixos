# Aggregate PiKVM NixOS module. Import this (exposed as
# `nixosModules.pikvm` / `.default`) to get the full stack; individual
# feature modules are toggled through their own `services.pikvm.*` options.
{ ... }:
{
  imports = [
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
    # ./webterm.nix is imported by ./nginx.nix (the web front-door owns it).
  ];

  # Make the PiKVM package scope (`pkgs.pikvm.*`) available to every module
  # and to the system itself.
  nixpkgs.overlays = [ (import ../overlays) ];
}
