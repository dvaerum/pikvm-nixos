# it-03400 — the real Pi4B hardware-verification appliance
# (pikvm-nixos@it-03400's node). Named in 6+ files across the repo and has
# caught both of this session's real production bugs (the CSI/EDID video
# issue, the HID-latch healthy-states misconfiguration) despite never having
# had its own host file — it's been informally "tracking #rpi4". Give it one,
# so it's evaluated by CI on every run instead of validated exclusively
# against an out-of-repo machine.
{
  imports = [
    ./boards/rpi4.nix
    ./profiles/appliance-stack.nix
  ];

  services.pikvm.deployment.target = {
    kind = "desktop";
    alwaysAttached = false;
  };
  services.pikvm.deployment.updateRef = "#it-03400";

  # Coordinate timing with nixos-developer-system's Track C (local-display).
  # captureConnector = HDMI-A-1: this box's actual cable is physically on
  # HDMI-A-1, not the module's default HDMI-A-2 (confirmed via
  # /sys/class/drm/*/status). Without this override, fixed mode (also the
  # default, left as-is here — auto's replug recovery isn't HW-characterized
  # yet, that's the separate #52 tracer question) pins to a permanently
  # disconnected port and never renders anything. 2026-08-27,
  # pikvm-nixos@it-03400.
  services.pikvm.localDisplay = {
    enable = true;
    captureConnector = "HDMI-A-1";
  };
}
