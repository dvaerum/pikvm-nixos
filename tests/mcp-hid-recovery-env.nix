# Regression guard for the composed-runtime-env class of bug that produced the
# pikvm01 field incident (fixed in 44038f4): when the built-in MCP is default-on,
# the HID-recovery endpoint must auto-enable AND its PIKVM_HID_RECOVERY_URL (+ the
# token EnvironmentFile) must actually be wired into the realized pikvm-mcp unit —
# otherwise the MCP's pikvm_hid_recover (M0 self-recovery) and health_check UDC
# ground-truth (M4) tools are decorative. Phase 2 flipped the MCP default-on but
# left the endpoint behind `mkEnableOption` (off), so the wiring — which sits
# inside `mkIf endpoint.enable` — silently never happened.
#
# Static unit inspection catches the missing Environment= line, but this asserts
# it on a BOOTED system (`systemctl show pikvm-mcp`) so the guard survives any
# future refactor of how the env is composed. Deliberately SCOPED to that
# assertion: just the MCP wrapper + the two hid-recovery modules, endpoint left
# at its DEFAULT (must follow the MCP) — no kvmd/nginx/otg (the URL wiring is
# independent of them), and we never wait for pikvm-mcp to reach active
# (onnxruntime need not start; `systemctl show` reads the composed unit either
# way), keeping the VM light. @nixos-developer-system runs the booted VM.
{ self, pkgs }:
{
  name = "pikvm-mcp-hid-recovery-env";

  nodes.machine =
    { ... }:
    {
      imports = [
        # hid-recovery-endpoint.nix transitively imports runtime-paths.nix,
        # mcp-integration.nix, and hid-recovery.nix — see module-list.nix /
        # Round-2 Phase 2 for why each module now imports its own declarers,
        # which is what makes this list this short (still no kvmd/nginx/otg —
        # the URL wiring this test asserts is independent of them, per the
        # header above).
        ../modules/hid-recovery-endpoint.nix
        self.nixosModules.mcp-server # services.pikvm-mcp (defaults enable = true)
      ];

      # The faithful default: MCP on, and the endpoint left at its DEFAULT so the
      # test proves `default = services.pikvm-mcp.enable` actually turns it on and
      # wires the env. (Do NOT set hidRecovery.endpoint.enable here — that's the
      # whole point.)
      services.pikvm-mcp.enable = true;

      virtualisation.memorySize = 3072;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    start_all()

    # The endpoint auto-enabled by the MCP-on default → its token + server units
    # exist and come up (both are light; independent of kvmd).
    machine.wait_for_unit("pikvm-hid-recovery-token.service")
    machine.wait_for_unit("pikvm-hid-recovery-endpoint.service")

    # THE GUARD: the realized pikvm-mcp unit carries PIKVM_HID_RECOVERY_URL. This
    # is exactly the env Phase 2 dropped. `systemctl show -p Environment` reads
    # the composed unit regardless of whether pikvm-mcp reached active (so we
    # don't pay for an onnxruntime start), making this a cheap, direct assertion.
    env = machine.succeed("systemctl show pikvm-mcp.service -p Environment")
    assert "PIKVM_HID_RECOVERY_URL=http://127.0.0.1:8082/hid-recovery" in env, \
        f"pikvm-mcp must carry the HID-recovery URL (M0/M4 wiring); got: {env!r}"

    # ...and the runtime token EnvironmentFile is wired in (the shared secret is a
    # /run path, never the store).
    envfiles = machine.succeed("systemctl show pikvm-mcp.service -p EnvironmentFiles")
    assert "/run/pikvm-hid-recovery/mcp.env" in envfiles, \
        f"pikvm-mcp must load the HID-recovery token env file; got: {envfiles!r}"

    # ...and pikvm-mcp is ordered AFTER the token provisioner, so the URL + token
    # are present before it starts (not a race).
    after = machine.succeed("systemctl show pikvm-mcp.service -p After")
    assert "pikvm-hid-recovery-token.service" in after, \
        f"pikvm-mcp must start after the token is provisioned; got: {after!r}"

    # The endpoint↔MCP shared token + the mcp.env it reads are actually provisioned.
    machine.succeed("test -s /run/pikvm-hid-recovery/token")
    machine.succeed("grep -q PIKVM_HID_RECOVERY_TOKEN /run/pikvm-hid-recovery/mcp.env")
  '';
}
