# Aggregate PiKVM NixOS module. Import this (exposed as
# `nixosModules.pikvm` / `.default`) to get the full stack; individual
# feature modules are toggled through their own `services.pikvm.*` options.
{ ... }:
{
  imports = [
    ./system/auto-upgrade.nix
    # ./ustreamer.nix
    # ./kvmd.nix
    # ./otg.nix
  ];
}
