# The complete, opinionated PiKVM appliance as a single importable NixOS
# module. This is the entry point for downstream users: import
# `pikvm-nixos.nixosModules.appliance` into your own nixosSystem and you get
# the universal multi-board image, the PiKVM services (auto-detecting the
# platform), the package overlay, and sensible appliance defaults — then just
# override hostname, SSH keys, timezone, the auto-upgrade source, etc.
#
# If you only want the options/packages (to compose your own system), import
# `pikvm-nixos.nixosModules.pikvm` and the overlay instead.
{ ... }:
{
  imports = [
    ../modules # services.pikvm.* options + the pikvm package overlay
    ./common.nix # flakes, ssh, users, gc, self-update defaults
    ./universal.nix # multi-board SD image + kvmd(auto) + OTG enabled
  ];
}
