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

  # PIKVM_ML_DISABLE_CPU_MEM_ARENA=1 (pikvm_mcp_server #99): disables the
  # cascade verifier's ONNX Runtime CPU memory arena. Confirmed on this exact
  # hardware (2026-09-01): the arena is the direct root cause of a full day
  # of recurring OOM/whole-system-starvation incidents — with it enabled
  # (the default), the FIRST real cascade call (e.g. pikvm_hid_recover, which
  # calls findCursorByV8FullFrame) permanently grows pikvm-mcp's RSS from
  # ~123MB to 2.89GB for the rest of the process's life, on a box with only
  # 3.6GB total RAM. With the flag set, the same call peaks at 1.51GB
  # transient and settles to 319.8MB steady-state — ~9x less. No accuracy
  # cost expected (arena allocator is purely a performance/reuse
  # optimization, not a correctness one), but this hasn't been separately
  # timing-benchmarked here — if cascade latency regresses meaningfully on
  # real hardware, that's the tradeoff to revisit.
  services.pikvm.mcp.extraEnv.PIKVM_ML_DISABLE_CPU_MEM_ARENA = "1";
}
