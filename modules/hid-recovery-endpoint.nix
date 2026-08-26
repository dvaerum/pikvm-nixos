# The authenticated loopback HID-recovery endpoint — the integration half of
# the HID-recovery feature. The privileged executor + the templated root units
# `pikvm-hid-recover@<action>.service` + the polkit rule live in
# `services.pikvm.hidRecovery` (modules/hid-recovery.nix, kvmd lane).
#
# Flow: the MCP server's `pikvm_hid_recover` tool POSTs {"action": ...} + a
# bearer token to this loopback endpoint; we validate the token and
# `systemctl start pikvm-hid-recover@<action>.service` (polkit grants our user
# start-only on those units — no sudo/setuid). We also wire
# PIKVM_HID_RECOVERY_URL / PIKVM_HID_RECOVERY_TOKEN into services.pikvm-mcp so
# the tool discovers us. Off unless `services.pikvm.hidRecovery.endpoint.enable`.
#
# Shared shape (user/group, token oneshot, hardened unit) comes from
# modules/lib/loopback-endpoint.nix; route logic (POST /hid-recovery, GET
# /hid-recovery/udc-state + /latch-status) is modules/hid-recovery-routes.py,
# readFile'd in unmodified.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hidRecoveryCfg = config.services.pikvm.hidRecovery;
  cfg = hidRecoveryCfg.endpoint;
  runtimePaths = config.services.pikvm.runtimePaths;

  mkLoopbackEndpoint = import ./lib/loopback-endpoint.nix { inherit lib config pkgs; };

  # The action set is the MCP trigger contract (docs/runbooks/hid-recovery.md);
  # instance names are the action strings verbatim (mixed separators intact).
  handlerEnv = ''
    ACTIONS = {"soft_connect", "udc-rebind", "reboot"}
    UDC_ROOT = "/sys/class/udc"
    # The HID-latch monitor (services.pikvm.hidLatchMonitor) writes its latest
    # classification here each sample; we serve it read-only at
    # GET /hid-recovery/latch-status (see docs/decisions/0003-hid-latch-monitor.md).
    LATCH_STATUS_PATH = "${runtimePaths.hidLatchStatus.path}"
  '';
in
{
  # runtime-paths.nix, mcp-integration.nix, hid-recovery.nix: this module
  # reads all three — see module-list.nix / Round-2 Phase 2 for why every
  # module now imports its own declarers directly instead of relying on the
  # aggregate.
  imports = [
    ./runtime-paths.nix
    ./mcp-integration.nix
    ./hid-recovery.nix
  ];

  options.services.pikvm.hidRecovery.endpoint = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # DEFAULT-ON whenever the built-in MCP is enabled. The MCP's
      # pikvm_hid_recover (M0 self-recovery) and health_check UDC ground-truth
      # (M4) tools are DECORATIVE without this loopback endpoint + the
      # PIKVM_HID_RECOVERY_URL wiring below — the one tool that fixes an HID-down
      # no-ops on the box that needs it. Phase 2 made the MCP default-on but left
      # this behind; tie it to the MCP so a faithful default appliance has
      # self-recovery working out of the box. Loopback-only (no firewall port),
      # token auto-generated at first boot, polkit-least-privilege → safe to
      # default on. Stays off when the MCP is off (e.g. zero2w), where it would
      # be a pointless idle server. Set explicitly to override either way.
      default = config.services.pikvm.mcp.enabled;
      defaultText = lib.literalExpression "config.services.pikvm.mcp.enabled";
      example = true;
      description = ''
        The authenticated loopback HID-recovery endpoint that lets the MCP server
        trigger the pikvm-hid-recover@<action> units and read the ground-truth
        UDC state (POST /hid-recovery, GET /hid-recovery/udc-state). Enabling it
        also wires PIKVM_HID_RECOVERY_URL + the bearer token into the pikvm-mcp
        service env. Defaults on when services.pikvm-mcp is enabled.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Loopback port the endpoint listens on (POST /hid-recovery).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/pikvm-hid-recovery-token";
      description = ''
        Bearer token shared between this endpoint and the MCP server. When null
        (default) a random token is generated at first boot. Point at a
        sops/agenix secret to manage it yourself.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Pull in the privileged executor + units + polkit (kvmd lane), whose
      # triggerUser defaults to the user we create below — but reads back
      # THIS module's own dedicated user via hidRecoveryCfg.triggerUser
      # rather than a hardcoded literal, so overriding triggerUser actually
      # moves both sides of the polkit grant together (the executor's rule
      # and this endpoint's user) instead of silently splitting them.
      services.pikvm.hidRecovery.enable = true;
    }
    (mkLoopbackEndpoint {
      description = "PiKVM HID-recovery";
      name = "hid-recovery";
      user = hidRecoveryCfg.triggerUser;
      port = cfg.port;
      tokenFile = cfg.tokenFile;
      tokenChannel = runtimePaths.hidRecoveryToken;
      mcpEnvChannel = runtimePaths.hidRecoveryMcpEnv;
      mcpEnvVar = "PIKVM_HID_RECOVERY_TOKEN";
      handler = builtins.readFile ./hid-recovery-routes.py;
      inherit handlerEnv;
    })
    # Point the MCP server at us — static URL as an env var; the secret token
    # via the runtime EnvironmentFile. Only when pikvm-mcp is actually
    # present. Written to the ALWAYS-DECLARED services.pikvm.mcp.extraEnv
    # proxy (modules/mcp-integration.nix), not services.pikvm-mcp.extraEnv
    # directly — that option only exists when the upstream module is
    # imported, and a module gating its OWN write on that presence (even via
    # a structural lib.optional, not just a bare mkIf) is a confirmed
    # infinite recursion (see mcp-integration.nix's header for the real `nix
    # eval --show-trace` finding). The proxy forwards this unconditionally
    # and harmlessly when MCP isn't declared — this module never needs to
    # know or care.
    (lib.mkIf config.services.pikvm.mcp.enabled {
      services.pikvm.mcp.extraEnv.PIKVM_HID_RECOVERY_URL =
        "http://127.0.0.1:${toString cfg.port}/hid-recovery";
    })
  ]);
}
