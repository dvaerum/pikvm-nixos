# The PiKVM stack-enablement stanza — identical across every appliance-style
# host (rpi4, zero2w, universal, it-03400, …), previously duplicated verbatim
# in each board's host file. Board facts (gpu_mem, TC358743 pins, bootloader)
# live in hosts/boards/*.nix instead; per-deployment specifics (hostname
# override, HID target, self-update ref) live in each host's own file, via
# modules/deployment.nix.
#
# Every option here is `mkDefault` so a per-deployment host file (or a board
# file, for the rare board-specific override like zero2w's MCP-too-heavy
# case) can freely override it without fighting priority — that's also what
# lets hosts migrate to this profile one at a time, each independently
# eval-green, rather than needing one atomic flag-day commit.
{ lib, ... }:
{
  networking.hostName = lib.mkDefault "pikvm";

  # The PiKVM stack. Platform is "auto" — the detector resolves the actual
  # capture/HID profile (CSI vs USB) at boot even though the board is known
  # at eval time.
  services.pikvm.kvmd.enable = lib.mkDefault true;
  services.pikvm.kvmd.platform = lib.mkDefault "auto";
  services.pikvm.otg.enable = lib.mkDefault true;
}
