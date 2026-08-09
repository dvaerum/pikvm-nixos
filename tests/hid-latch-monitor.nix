# VM test for the HID-latch monitor (#hid-latch, modules/hid-latch-monitor.nix +
# the GET /hid-recovery/latch-status route in hid-recovery-endpoint.nix). Proves
# the manager's VM gate: the service STARTS, reads the LOCAL UDC, emits a valid
# status.json, and the loopback endpoint SERVES it (auth-gated).
#
# This is NOT the FIRE gate — a sustained-unhealthy latch fires only after the
# ≥90s persistence window, and the substitution-free FIRE (unbind → function
# empty → latched→udc-rebind) is it-03400's on-appliance HW gate (the real trust
# boundary for the local path per ADR 0003). Here we validate the healthy,
# quiet-and-serving path on a bound gadget.
#
# dummy_hcd gives a virtual UDC so kvmd-otg binds and the gadget assembles; with
# nothing plugged into the virtual host the UDC reads "not attached", which — WHILE
# BOUND — is healthy under the default acceptable-state set (bound-ness is the real
# gate). The built-in MCP SERVICE is left off (we only need the bin, which ships in
# the pikvm-mcp-server package, + the hid-recovery endpoint). @nixos-developer-system
# runs the booted VM.
{ self, pkgs }:
{
  name = "pikvm-hid-latch-monitor";

  nodes.machine = {
    imports = [
      ../modules/kvmd.nix
      ../modules/otg.nix
      ../modules/hid-recovery.nix
      ../modules/hid-recovery-endpoint.nix
      ../modules/hid-latch-monitor.nix
      self.nixosModules.mcp-server # declares services.pikvm-mcp (left off here)
    ];

    services.pikvm.kvmd.enable = true;
    services.pikvm.kvmd.platform = "auto";
    services.pikvm.otg.enable = true;
    boot.kernelModules = [ "dummy_hcd" ];

    # MCP service OFF (skips onnxruntime at runtime) but the endpoint is what
    # serves latch-status — enable it explicitly, and the monitor is default-on
    # with otg. The bin still comes from the pikvm-mcp-server package.
    services.pikvm-mcp.enable = false;
    services.pikvm.hidRecovery.endpoint.enable = true;

    services.pikvm.kvmd.settings.kvmd = {
      msd.type = "disabled";
      atx.type = "disabled";
    };

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 8192; # the pikvm-mcp-server closure (onnxruntime) is large
  };

  testScript = ''
    import json

    start_all()
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("pikvm-hid-recovery-endpoint.service")
    # (1) the monitor STARTS and stays up (report-only reader; Restart=always).
    machine.wait_for_unit("pikvm-hid-latch-monitor.service")

    # (2) it reads the LOCAL UDC and EMITS a status.json. dummy_hcd binds the
    # gadget (function=kvmd) with nothing attached → state "not attached", which
    # while BOUND is healthy under the default set (bound-ness is the real gate).
    machine.wait_for_file("/run/pikvm-hid-latch/status.json")
    status = json.loads(machine.succeed("cat /run/pikvm-hid-latch/status.json"))
    assert status["bound"] is True, status          # /sys/class/udc/<udc>/function non-empty
    assert status["healthy"] is True, status         # bound AND state in the acceptable set
    assert status["alert"] is False, status          # not latched
    assert "lastSampleAt" in status, status          # the on-box dead-man liveness field

    # (3) the LOOPBACK ENDPOINT SERVES it — auth-gated (401 without the bearer),
    # and a cross-user read (endpoint user reads the monitor's status file, so this
    # also proves the file is world-readable, not root-only).
    tok = machine.succeed("cat /run/pikvm-hid-recovery/token").strip()
    code = machine.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/hid-recovery/latch-status"
    ).strip()
    assert code == "401", code
    got = json.loads(machine.succeed(
        f"curl -s -H 'Authorization: Bearer {tok}' http://127.0.0.1:8082/hid-recovery/latch-status"
    ))
    assert got.get("available") is True, got
    assert got["bound"] is True and got["healthy"] is True and got["alert"] is False, got

    # (4) the existing udc-state GET still works (composition regression guard: we
    # only ADDED a route + a helper to the endpoint).
    udc = json.loads(machine.succeed(
        f"curl -s -H 'Authorization: Bearer {tok}' http://127.0.0.1:8082/hid-recovery/udc-state"
    ))
    assert "state" in udc and "online" in udc, udc
  '';
}
