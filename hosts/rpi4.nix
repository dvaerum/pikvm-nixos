# Raspberry Pi 4 — the required target, on the Raspberry Pi vendor kernel.
#
# Board facts (vendor kernel, disko, boot mode) live in hosts/boards/rpi4.nix;
# stack-enablement lives in hosts/profiles/appliance-stack.nix. This file is
# just the deployment-level facts: self-update ref, plus the note below.
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

  # NOTE: this kiosk's KVM target is an iPad (relative-only HID), but the MCP no
  # longer takes a static `services.pikvm-mcp.target`. Post-#46 the MCP derives
  # its HID mode from the appliance's GET /hidmode (wired as
  # services.pikvm-mcp.hidModeUrl in modules/hidmode-endpoint.nix, which also sets
  # target = null) and is stateless about mode — the appliance's runtime hidMode
  # switch + its persisted marker is the single source of truth. A static target
  # here would be redundant and, with the URL present, an eval error (the #46
  # module rejects both-set). The iPad default is expressed via
  # services.pikvm.kvmd.hidMode on the appliance, not here.
}
