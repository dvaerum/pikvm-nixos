# Aggregate PiKVM NixOS module. Import this (exposed as
# `nixosModules.pikvm` / `.default`) to get the full stack; individual
# feature modules are toggled through their own `services.pikvm.*` options.
{ ... }:
{
  imports = [
    ./system/auto-upgrade.nix
    ./otg.nix
    ./kvmd.nix
    ./nginx.nix
  ];

  # Make the PiKVM package scope (`pkgs.pikvm.*`) available to every module
  # and to the system itself.
  nixpkgs.overlays = [ (import ../overlays) ];
}
