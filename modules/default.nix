# Aggregate PiKVM module. Import this (exposed as `nixosModules.pikvm` /
# `.default`) to get the full stack; individual feature modules are toggled
# through their own `services.pikvm.*` options.
#
# The module graph itself lives in ./module-list.nix, kept separate from the
# overlay below — see that file's header for why.
{ ... }:
{
  imports = [ ./module-list.nix ];

  # Make the PiKVM package scope (`pkgs.pikvm.*`) available to every module
  # and to the system itself.
  nixpkgs.overlays = [ (import ../overlays) ];
}
