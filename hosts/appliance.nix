# The complete, opinionated PiKVM appliance as a single importable NixOS
# module. This is the entry point for downstream users: import
# `pikvm-nixos.nixosModules.appliance` into your own nixosSystem and you get
# the universal multi-board image, the PiKVM services (auto-detecting the
# platform), the package overlay, and sensible appliance defaults — then just
# override hostname, SSH keys, timezone, the auto-upgrade source, etc.
#
# If you only want the options/packages (to compose your own system), import
# `pikvm-nixos.nixosModules.pikvm` and the overlay instead.
#
# This is a PUBLIC output (README.md + template/flake.nix consume it, and
# hosts/default.nix's `universal` nixosConfiguration is built from exactly
# this module) — don't rename/remove it. Board facts + stack-enablement live
# in hosts/boards/universal.nix + hosts/profiles/appliance-stack.nix so this
# file stays a thin, stable composition point.
{ lib, ... }:
{
  imports = [
    ../modules # services.pikvm.* options + the pikvm package overlay
    ./common.nix # flakes, ssh, users, gc, self-update defaults
    ./boards/universal.nix # multi-board SD image, board facts only
    ./profiles/appliance-stack.nix # hostName/kvmd(auto)/OTG stack-enablement
  ];

  # Devices self-update from THIS configuration (the hostname is "pikvm" but
  # the flake attribute is "universal"). mkDefault so a downstream consumer's
  # own autoUpgrade.flake override (see template/flake.nix) still wins.
  services.pikvm.deployment.updateRef = lib.mkDefault "#universal";
}
