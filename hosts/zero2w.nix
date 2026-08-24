# Raspberry Pi Zero 2 W — the bonus target, on the RPi vendor kernel.
#
# Board facts (vendor kernel, disko, TC358743 pins) live in
# hosts/boards/zero2w.nix; stack-enablement lives in
# hosts/profiles/appliance-stack.nix. Install with:
#
#   nix run .#install-sd -- --board zero2w /dev/diskX
{ lib, ... }:
{
  imports = [
    ./boards/zero2w.nix
    ./profiles/appliance-stack.nix
  ];

  services.pikvm.deployment.updateRef = lib.mkDefault "#zero2w";

  # The built-in MCP (onnxruntime + the detection stack) is too heavy for a
  # Zero 2 W, so it defaults OFF here — the faithful PiKVM web dashboard
  # (services.pikvm.web) stays default-ON. mkOverride 500 wins over the general
  # mkDefault-true from the mcp-server wrapper (flake.nix) while staying
  # user-overridable: `services.pikvm-mcp.enable = true;` re-enables it.
  services.pikvm-mcp.enable = lib.mkOverride 500 false;
}
