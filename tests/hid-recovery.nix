# VM test for the HID-recovery privileged host ops (modules/hid-recovery.nix).
#
# Boots a real kvmd + OTG gadget on dummy_hcd (same VM accommodation as
# kvmd-services: msd/atx disabled, which the generic VM kernel can't provide),
# so there is an actual bound USB gadget + UDC to recover. Then it proves:
#   * pikvm-hid-recover@soft_connect and @udc-rebind actually run and leave the
#     UDC re-enumerated ("configured") — the real recovery, not a no-op;
#   * the polkit least-privilege grant — the endpoint's triggerUser may start
#     ONLY the pikvm-hid-recover@ units, nothing else.
# `reboot` is not exercised (it would reboot the test VM); it's real-rig only.
#
# The endpoint half (authenticated loopback → systemctl start) is a separate
# module; here we stub only its user so the polkit subject exists.
{ self, pkgs }:
{
  name = "pikvm-hid-recovery";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/kvmd.nix
        ../modules/otg.nix
        ../modules/hid-recovery.nix
        ../modules/hid-recovery-endpoint.nix
        # Declares services.pikvm-mcp so the endpoint's MCP-wiring definition
        # resolves. Left DISABLED (default) — the endpoint runs standalone here;
        # we test the loopback → systemctl path, not the MCP round-trip.
        self.nixosModules.mcp-server
      ];

      services.pikvm.kvmd.enable = true;
      services.pikvm.kvmd.platform = "auto";
      services.pikvm.otg.enable = true;
      # Same VM-hardware accommodation as kvmd-services.nix: the generic kernel
      # can't do the vendor MSD cdrom attr or /dev/gpiochip0, and kvmd would
      # crash-loop; disable those so kvmd comes up and the HID gadget binds.
      services.pikvm.kvmd.settings.kvmd = {
        msd.type = "disabled";
        atx.type = "disabled";
      };
      boot.kernelModules = [ "dummy_hcd" ];

      # The endpoint module pulls in services.pikvm.hidRecovery.enable AND
      # creates the pikvm-hid-recovery user + the loopback endpoint + token for
      # real — so we exercise the full endpoint → systemctl path, not a stub.
      services.pikvm.hidRecovery.endpoint.enable = true;

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    start_all()

    # kvmd-otg binds the composite gadget on dummy_hcd's virtual UDC; the
    # dummy_hcd loopback host then enumerates it to "configured".
    machine.wait_for_unit("kvmd-otg.service")
    udc = machine.succeed("ls /sys/class/udc | head -n1").strip()
    assert udc, "no UDC registered under /sys/class/udc"
    print(f"UDC = {udc}")
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- soft_connect: the primary ~6s recovery -------------------------
    machine.succeed("systemctl start pikvm-hid-recover@soft_connect.service")
    machine.succeed("journalctl -u pikvm-hid-recover@soft_connect.service | grep -q 'soft_connect on'")
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- udc-rebind: idempotent, must NOT hit the kvmd-otg FileExistsError ---
    machine.succeed("systemctl start pikvm-hid-recover@udc-rebind.service")
    machine.succeed("journalctl -u pikvm-hid-recover@udc-rebind.service | grep -q 'udc-rebind'")
    # run it a SECOND time to prove idempotency (rebind on an already-bound UDC)
    machine.succeed("systemctl start pikvm-hid-recover@udc-rebind.service")
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- polkit least-privilege -----------------------------------------
    # The endpoint's user may start ONLY the recovery units...
    machine.succeed(
        "runuser -u pikvm-hid-recovery -- systemctl start pikvm-hid-recover@soft_connect.service"
    )
    # ...and nothing else (an arbitrary unit is denied by polkit, non-interactive).
    machine.fail(
        "runuser -u pikvm-hid-recovery -- systemctl start systemd-tmpfiles-clean.service"
    )

    # --- endpoint: authenticated loopback → systemctl start -------------
    # The pikvm-hid-recovery endpoint (running as that user) Bearer-authenticates
    # the MCP contract and starts the recovery unit — the full end-to-end path.
    machine.wait_for_unit("pikvm-hid-recovery-endpoint.service")
    token = machine.succeed("cat /run/pikvm-hid-recovery/token").strip()

    def post(auth, body):
        cmd = (
            "curl -s -o /dev/null -w '%{http_code}' "
            + auth
            + " -H 'Content-Type: application/json' -X POST"
            + " http://127.0.0.1:8082/hid-recovery -d '" + body + "'"
        )
        return machine.succeed(cmd).strip()

    bearer = "-H 'Authorization: Bearer " + token + "'"
    # no token / wrong token → 401
    assert post("", '{"action": "soft_connect"}') == "401", "missing token must be 401"
    assert post("-H 'Authorization: Bearer wrong'", '{"action": "soft_connect"}') == "401", \
        "wrong token must be 401"
    # unknown action → 400 (validated before any systemctl)
    assert post(bearer, '{"action": "nope"}') == "400", "unknown action must be 400"
    # valid token + real action → 200, and the recovery actually ran (UDC configured)
    assert post(bearer, '{"action": "soft_connect"}') == "200", "authenticated trigger must be 200"
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- read-only UDC-state route (M4: ground truth for the MCP health_check) ---
    # GET /hid-recovery/udc-state serves the live /sys/class/udc/<udc>/state,
    # Bearer-authenticated like the POST actions but a pure world-readable sysfs
    # read (no root/polkit/systemctl). The gadget is bound+configured above, so
    # ground truth == "configured"; unauthenticated reads are refused.
    def get(auth):
        return machine.succeed(
            "curl -s -o /tmp/udc -w '%{http_code}' "
            + auth
            + " http://127.0.0.1:8082/hid-recovery/udc-state"
        ).strip()

    assert get("") == "401", "unauthenticated udc-state must be 401"
    assert get(bearer) == "200", "authenticated udc-state must be 200"
    machine.succeed(f"grep -qE '\"udc\": *\"{udc}\"' /tmp/udc")
    machine.succeed("grep -qE '\"state\": *\"configured\"' /tmp/udc")
    # derived ground-truth HID-live flag the MCP health_check consumes
    machine.succeed("grep -qE '\"online\": *true' /tmp/udc")

    # --- 502 on a failed recovery: the M0 escalation trigger ------------
    # Unbind the gadget so soft_connect can't complete: the UDC dir stays
    # present (find_udc still succeeds) but the soft_connect sysfs write is
    # rejected (EOPNOTSUPP) on an unbound UDC, so the oneshot exits non-zero
    # and the endpoint MUST surface 502 — the status the MCP M0 ladder
    # escalates on (soft_connect → udc-rebind). (In dummy_hcd the state node
    # keeps reading "configured" after unbind, so this exercises the write-
    # error branch rather than a wait_configured timeout — same rc=1 → 502
    # contract either way.) Fails fast; rebinds after so it doesn't disturb
    # the rig for any later step.
    gadget = "/sys/kernel/config/usb_gadget/kvmd"
    machine.succeed(f'echo "" > {gadget}/UDC')
    assert post(bearer, '{"action": "soft_connect"}') == "502", \
        "a failed soft_connect must surface as 502 (M0 escalation trigger)"
    machine.succeed(f'echo "{udc}" > {gadget}/UDC')
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )
  '';
}
