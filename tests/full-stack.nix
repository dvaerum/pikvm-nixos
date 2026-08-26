# Full-composition smoke test (Round-2 Phase 2, 2c — optional but
# recommended). The per-module tests exercise one feature deeply, in
# isolation; nothing else in this repo boots EVERY module-list.nix module +
# nixosModules.mcp-server on the same node at once, so a cross-module conflict
# that only surfaces when the whole stack is live (option collisions, a
# systemd unit two modules both try to define, an assertion two modules'
# defaults jointly trip) has no VM-level check catching it — only eval-only
# host-eval does, and only for actual host configs, not the raw module set.
#
# `imports = [ ../modules/module-list.nix self.nixosModules.mcp-server ]` is
# exactly hosts/appliance.nix's own composition (minus its board/common
# layers) — already confirmed to evaluate during the Round-2 investigation.
# This promotes that from "evaluates" to "boots and the daemons come up".
{ self, pkgs }:
{
  name = "pikvm-full-stack";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/module-list.nix
        self.nixosModules.mcp-server
      ];

      services.pikvm.kvmd.enable = true;
      services.pikvm.kvmd.platform = "auto";
      services.pikvm.otg.enable = true;
      services.pikvm.web.enable = true;
      # hidMode, its endpoint, and hidLatchMonitor all default on once
      # otg.enable + mcp.enabled are true (see each module's `enable` option)
      # — only hidRecovery needs an explicit opt-in (mkEnableOption, no
      # otg-derived default), same as every other test that wants it.
      services.pikvm.hidRecovery.enable = true;

      # Same VM-hardware accommodations as kvmd-services.nix/mcp-proxy.nix:
      # dummy_hcd for a virtual UDC, msd/atx disabled (both touch configfs
      # attrs / device nodes this generic VM kernel doesn't have).
      boot.kernelModules = [ "dummy_hcd" ];
      services.pikvm.kvmd.settings.kvmd = {
        msd.type = "disabled";
        atx.type = "disabled";
      };

      # Every module's daemons + the MCP server (onnxruntime) co-resident.
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    start_all()

    # Core stack.
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("pikvm-mcp.service")

    # Every endpoint/monitor unit that should be default-on with this config.
    machine.wait_for_unit("pikvm-hidmode-endpoint.service")
    machine.wait_for_unit("pikvm-hid-recovery-endpoint.service")
    machine.wait_for_unit("pikvm-hid-latch-monitor.service")

    # All four daemons must still be up a moment later — proves the stack
    # didn't just start-then-crash-loop from a cross-module conflict (the
    # exact failure class this check exists to catch).
    for unit in (
        "kvmd.service",
        "nginx.service",
        "pikvm-mcp.service",
        "pikvm-hidmode-endpoint.service",
        "pikvm-hid-recovery-endpoint.service",
        "pikvm-hid-latch-monitor.service",
    ):
        state = machine.succeed(f"systemctl is-active {unit}").strip()
        assert state == "active", f"{unit}: expected active, got {state!r}"

    # The MCP server must actually be reachable through the real front-door
    # (proves nginx's /mcp proxy_pass + pikvm-mcp's own bind both came up
    # correctly in this full composition, not just "the units exist").
    code = machine.succeed(
        "curl -sk -o /dev/null -w '%{http_code}' https://localhost/mcp"
    ).strip()
    assert code in ("400", "406"), f"unexpected /mcp status with no body: {code}"
  '';
}
