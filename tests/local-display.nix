# VM + eval-level test for services.pikvm.localDisplay (modules/local-display.nix).
# See docs/decisions/0004-local-display.md.
#
# Two kinds of gate:
#
#   (1) EVAL-LEVEL, static (below, outside testScript): assert the unit's SHAPE
#       — DeviceAllow contains "char-tty rw", Conflicts contains the derived
#       getty unit, TTYPath agrees with it — directly off the already-built
#       it-03400 host config (which has localDisplay.enable = true, the
#       coordination point from Phase 3). Fails eval instantly if violated,
#       same idiom as flake.nix's host-eval. NOTE: "DevicePolicy=closed" is
#       NOT checked here — it's systemd's own IMPLICIT runtime default once
#       DeviceAllow is set at all (see `man systemd.exec`), never written into
#       our nix config, so it isn't a nix-eval-visible fact; it's checked for
#       real in the VM below instead.
#
#   (2) VM, behavioural: stub `mpv` to capture its argv instead of touching
#       real DRM, point `sysfsDrmRoot` at fake connector/status files instead
#       of real DRM sysfs, and let the WHOLE supervisor (connector detection
#       -> pick_target -> exec) run for real. Assert:
#         (a) the unit survives — NRestarts==0 and no "Permission denied" in
#             its journal after ~20s. This is what actually reproduces the
#             DeviceAllow->DevicePolicy=closed crash-loop it-03400 found on a
#             real deploy (the denial is a systemd cgroup decision independent
#             of GPU presence, so a VM without real DRM still exercises it);
#         (b) DevicePolicy is genuinely "closed" at runtime (systemctl show);
#         (c) the stub's captured argv has the right --drm-connector and the
#             --demuxer-lavf-o=input_format=mjpeg hint;
#         (d) removing the rendered connector and connecting a different one
#             makes the supervisor re-render onto it (auto mode).
{ self, pkgs }:
let
  lib = pkgs.lib;

  # (1) Static unit-shape assertions, off the real it-03400 host config.
  svc = self.nixosConfigurations.it-03400.config.systemd.services.pikvm-local-display;
  gettyUnit = "getty@tty2.service"; # it-03400 uses the vt default (2)
in
assert lib.assertMsg (lib.elem "char-tty rw" svc.serviceConfig.DeviceAllow) ''
  pikvm-local-display: DeviceAllow must contain "char-tty rw" — dropping it
  flips DevicePolicy=closed and denies this unit's own TTYPath/
  StandardInput=tty-force, crash-looping with Permission denied
  (HW-confirmed regression, it-03400 2026-08-24). Got: ${builtins.toJSON svc.serviceConfig.DeviceAllow}
'';
assert lib.assertMsg (lib.elem gettyUnit svc.conflicts) ''
  pikvm-local-display: Conflicts must contain ${gettyUnit} (races mpv for VT
  ownership on a physical VT switch otherwise). Got: ${builtins.toJSON svc.conflicts}
'';
assert lib.assertMsg (svc.serviceConfig.TTYPath == "/dev/tty2") ''
  pikvm-local-display: TTYPath must agree with ${gettyUnit} (both derived from
  the same `vt` option). Got: ${svc.serviceConfig.TTYPath}
'';
{
  name = "pikvm-local-display";

  nodes.machine =
    { pkgs, ... }:
    let
      # Captures argv instead of touching real DRM — the WHOLE supervisor
      # (bash control flow, connector polling, re-exec on change) still runs
      # for real; only the player binary is fake.
      stubMpv = pkgs.writeShellScriptBin "mpv" ''
        printf '%s\n' "$@" > /tmp/argv
        sleep infinity
      '';
    in
    {
      imports = [
        ../modules/kvmd.nix
        ../modules/otg.nix
        ../modules/local-display.nix
        self.nixosModules.mcp-server # declares services.pikvm-mcp (left off here)
      ];

      services.pikvm.kvmd.enable = true;
      services.pikvm.kvmd.platform = "auto";
      services.pikvm.otg.enable = true;
      boot.kernelModules = [ "dummy_hcd" ];
      services.pikvm-mcp.enable = false;

      services.pikvm.kvmd.settings.kvmd = {
        msd.type = "disabled";
        atx.type = "disabled";
      };

      services.pikvm.localDisplay = {
        enable = true;
        mode = "auto";
        package = stubMpv;
        sysfsDrmRoot = "/tmp/fake-drm";
      };

      # Fake DRM connector tree, root matching sysfsDrmRoot above. Starts with
      # HDMI-A-2 connected, HDMI-A-1 disconnected.
      systemd.tmpfiles.rules = [
        "d /tmp/fake-drm/card0-HDMI-A-1 0755 root root -"
        "d /tmp/fake-drm/card0-HDMI-A-2 0755 root root -"
        "f /tmp/fake-drm/card0-HDMI-A-1/status 0644 root root - disconnected"
        "f /tmp/fake-drm/card0-HDMI-A-2/status 0644 root root - connected"
      ];

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 8192; # the pikvm-mcp-server closure (onnxruntime) is large
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("pikvm-local-display.service")

    # (2a) the unit survives — no DeviceAllow/DevicePolicy crash-loop. Give it
    # a real window (systemd's own retry/backoff, plus the supervisor's own
    # poll cadence) rather than checking the instant it starts.
    machine.sleep(20)
    nrestarts = machine.succeed(
        "systemctl show pikvm-local-display.service -p NRestarts --value"
    ).strip()
    assert nrestarts == "0", f"pikvm-local-display restarted {nrestarts} times — crash-looping"
    journal = machine.succeed("journalctl -u pikvm-local-display.service --no-pager")
    assert "permission denied" not in journal.lower(), journal

    # (2b) DevicePolicy is genuinely "closed" at runtime (systemd's own implicit
    # default once DeviceAllow is set at all — not a nix-eval-visible fact, see
    # the file header).
    policy = machine.succeed(
        "systemctl show pikvm-local-display.service -p DevicePolicy --value"
    ).strip()
    assert policy == "closed", policy

    # (2c) the stub captured the right argv: rendering on the connected fake
    # connector (HDMI-A-2), with the load-bearing mjpeg demuxer hint.
    machine.wait_for_file("/tmp/argv")
    argv = machine.succeed("cat /tmp/argv")
    assert "--drm-connector=HDMI-A-2" in argv, argv
    assert "--demuxer-lavf-o=input_format=mjpeg" in argv, argv

    # (2d) move the cable: HDMI-A-2 disconnects, HDMI-A-1 connects. auto mode
    # should re-render onto HDMI-A-1 within its ~2s poll cadence.
    machine.succeed("echo disconnected > /tmp/fake-drm/card0-HDMI-A-2/status")
    machine.succeed("echo connected > /tmp/fake-drm/card0-HDMI-A-1/status")
    machine.wait_until_succeeds("grep -q -- '--drm-connector=HDMI-A-1' /tmp/argv", timeout=30)

    # still no crash after the re-render.
    nrestarts_after = machine.succeed(
        "systemctl show pikvm-local-display.service -p NRestarts --value"
    ).strip()
    assert nrestarts_after == "0", f"pikvm-local-display restarted {nrestarts_after} times after re-render"
  '';
}
