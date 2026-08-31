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
#       same idiom as flake.nix's host-eval.
#
#   (2) VM, behavioural: stub `mpv` to capture its argv instead of touching
#       real DRM, point `sysfsDrmRoot` at fake connector/status files instead
#       of real DRM sysfs, and let the WHOLE supervisor (connector detection
#       -> pick_target -> exec) run for real. Assert:
#         (a) the unit survives — NRestarts==0 and no "Permission denied" in
#             its journal after ~20s. This is what actually reproduces the
#             DeviceAllow-driven crash-loop it-03400 found on a real deploy
#             (the denial is a systemd cgroup decision independent of GPU
#             presence, so a VM without real DRM still exercises it);
#         (b) DeviceAllow is genuinely non-empty at runtime (systemctl show)
#             — the config-level fact that narrows this unit's access (see
#             `man systemd.resource-control`'s DevicePolicy=auto: "in addition,
#             allows access to all devices IF NO EXPLICIT DeviceAllow= IS
#             PRESENT" — DevicePolicy itself is NEVER reported as "closed"
#             unless a unit sets it explicitly, which ours doesn't; auto's
#             *effective* permissiveness narrows once DeviceAllow is
#             non-empty, but `systemctl show -p DevicePolicy` keeps reporting
#             "auto" regardless — confirmed empirically: a real VM run of
#             this test asserting DevicePolicy=="closed" failed with "auto"
#             even though (a) above proves the restriction IS live. See
#             docs/learnings/systemd-devicepolicy-auto.md);
#         (c) the stub's captured argv has the right --drm-connector and reads
#             ustreamer's own stream URL, never a raw v4l2 device (mjpeg is
#             the only mode since task_c9df75066f71, 2026-08-31);
#         (d) removing the rendered connector and connecting a different one
#             makes the supervisor re-render onto it (auto mode).
#
# (1) also asserts services.pikvm.kvmd.settings.kvmd.streamer.forever is
# auto-set true whenever localDisplay is enabled — the pairing fix that keeps
# kvmd from idle-stopping ustreamer out from under this mode's mpv client.
{ self, pkgs }:
let
  lib = pkgs.lib;

  # (1) Static unit-shape assertions, off the real it-03400 host config.
  svc = self.nixosConfigurations.it-03400.config.systemd.services.pikvm-local-display;
  hostCfg = self.nixosConfigurations.it-03400.config;
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
assert lib.assertMsg (hostCfg.services.pikvm.kvmd.settings.kvmd.streamer.forever == true) ''
  pikvm-local-display: services.pikvm.kvmd.settings.kvmd.streamer.forever must
  be auto-set true whenever localDisplay is enabled — without it kvmd can
  idle-stop ustreamer out from under an actively-streaming mpv client (its
  own WS-client accounting is blind to local-display's nginx-proxied mjpeg
  connection; task_c9df75066f71, 2026-08-31). Got: ${builtins.toJSON hostCfg.services.pikvm.kvmd.settings.kvmd.streamer.forever or null}
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
      # for real; only the player binary is fake. /run, NOT /tmp: the real
      # unit sets PrivateTmp=true, which gives it an isolated, initially-empty
      # private /tmp — content this test writes under the HOST's /tmp (via
      # tmpfiles.rules below, or a bare `cat`/`echo` from the test script) is
      # invisible to the unit under test, and vice versa. /run isn't touched
      # by PrivateTmp, so it's actually shared. See
      # docs/learnings/systemd-privatetmp-isolation.md (confirmed empirically:
      # a first pass at this test using /tmp for both the fake DRM tree and
      # this argv capture hung forever — the supervisor never saw the fixture
      # files, and this file would never have appeared either).
      stubMpv = pkgs.writeShellScriptBin "mpv" ''
        printf '%s\n' "$@" > /run/argv
        sleep infinity
      '';
    in
    {
      imports = [
        # kvmd.nix transitively imports otg.nix — see module-list.nix /
        # Round-2 Phase 2 for why each module now imports its own declarers.
        # local-display.nix is a leaf (nothing else imports it), so it still
        # needs listing explicitly.
        ../modules/kvmd.nix
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
        sysfsDrmRoot = "/run/fake-drm";
      };

      # Fake DRM connector tree, root matching sysfsDrmRoot above. Starts with
      # HDMI-A-2 connected, HDMI-A-1 disconnected. /run, not /tmp — see the
      # stubMpv comment above.
      systemd.tmpfiles.rules = [
        "d /run/fake-drm/card0-HDMI-A-1 0755 root root -"
        "d /run/fake-drm/card0-HDMI-A-2 0755 root root -"
        "f /run/fake-drm/card0-HDMI-A-1/status 0644 root root - disconnected"
        "f /run/fake-drm/card0-HDMI-A-2/status 0644 root root - connected"
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

    # (2b) DeviceAllow is genuinely non-empty at runtime — not a nix-eval-
    # visible fact by itself (systemctl's runtime rendering could in
    # principle differ from what nix wrote), see the file header for why this
    # is checked instead of DevicePolicy (which never reports "closed" here —
    # confirmed empirically, not just from the man page).
    device_allow = machine.succeed(
        "systemctl show pikvm-local-display.service -p DeviceAllow --value"
    ).strip()
    assert device_allow != "", "DeviceAllow is empty at runtime — the unit has no device restriction at all"

    # (2c) the stub captured the right argv: rendering on the connected fake
    # connector (HDMI-A-2), reading the shared ustreamer stream (never a raw
    # v4l2 device — that mode no longer exists, task_c9df75066f71 2026-08-31).
    machine.wait_for_file("/run/argv")
    argv = machine.succeed("cat /run/argv")
    assert "--drm-connector=HDMI-A-2" in argv, argv
    assert "streamer/stream" in argv, argv
    assert "v4l2" not in argv, argv

    # (2d) move the cable: HDMI-A-2 disconnects, HDMI-A-1 connects. auto mode
    # should re-render onto HDMI-A-1 within its ~2s poll cadence.
    machine.succeed("echo disconnected > /run/fake-drm/card0-HDMI-A-2/status")
    machine.succeed("echo connected > /run/fake-drm/card0-HDMI-A-1/status")
    machine.wait_until_succeeds("grep -q -- '--drm-connector=HDMI-A-1' /run/argv", timeout=30)

    # still no crash after the re-render.
    nrestarts_after = machine.succeed(
        "systemctl show pikvm-local-display.service -p NRestarts --value"
    ).strip()
    assert nrestarts_after == "0", f"pikvm-local-display restarted {nrestarts_after} times after re-render"
  '';
}
