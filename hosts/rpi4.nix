# Raspberry Pi 4 — the required target, on the Raspberry Pi vendor kernel.
#
# Board facts (vendor kernel, disko, boot mode) live in hosts/boards/rpi4.nix;
# stack-enablement lives in hosts/profiles/appliance-stack.nix. This file is
# just the deployment-level facts: the self-update ref. (The shared, stock
# desktop-default Pi4 — an iPad-specific note used to live here; it moved to
# hosts/pikvm01.nix, the one host it's actually true of.)
{ lib, ... }:
{
  imports = [
    ./boards/rpi4.nix
    ./profiles/appliance-stack.nix
  ];

  # Devices self-update from this configuration (attribute `rpi4`). mkDefault
  # so a per-box overlay like pikvm01.nix can override it with a plain
  # assignment (as it does).
  services.pikvm.deployment.updateRef = lib.mkDefault "#rpi4";
}
