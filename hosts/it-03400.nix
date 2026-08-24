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
  services.pikvm.localDisplay.enable = true;
}
