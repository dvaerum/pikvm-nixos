# The authenticated loopback HID-mode endpoint — the MCP-facing half of the
# runtime iPad/desktop switch (#51). The privileged executor + templated root
# units `pikvm-hidmode@<mode>.service` + the polkit rule live in hidmode.nix.
# Same split as hid-recovery{,-endpoint}.nix.
#
# Flow: the MCP server reads current mode via GET /hidmode and requests a switch
# via POST /hidmode {"mode": "ipad"} + a bearer token; we validate the token and
# `systemctl start --no-block pikvm-hidmode@<mode>.service` (polkit grants our
# user start-only on those units — no sudo/setuid). We also wire
# PIKVM_HIDMODE_URL / PIKVM_HIDMODE_TOKEN into services.pikvm-mcp so the tool
# discovers us. The appliance is the single source of truth for "current mode";
# the MCP READS it and follows (stays stateless about mode).
#
# Off unless `services.pikvm.kvmd.hidMode.endpoint.enable` (default: on when both
# the hidMode apparatus and the built-in MCP are enabled).
#
# Shared shape (user/group, token oneshot, hardened unit) comes from
# modules/lib/loopback-endpoint.nix; route logic (do_GET/do_POST) is
# modules/hidmode-routes.py, readFile'd in unmodified.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hidModeCfg = config.services.pikvm.kvmd.hidMode;
  cfg = hidModeCfg.endpoint;
  runtimePaths = config.services.pikvm.runtimePaths;

  mkLoopbackEndpoint = import ./lib/loopback-endpoint.nix { inherit lib config pkgs; };
  mkUnitPrefixGrant = import ./lib/unit-prefix-grant.nix { inherit lib; };

  # Module-level constants + helpers the routes fragment needs, inserted
  # BEFORE the shared handler.py's imports/class (see loopback-endpoint.nix's
  # `handlerEnv` doc for why the ordering is safe).
  handlerEnv = ''
    MODES = {"desktop", "ipad"}
    OVERRIDE = "${runtimePaths.hidmodeOverride.path}"
    GADGET = "/sys/kernel/config/usb_gadget/${runtimePaths.otgGadgetName}"

    # kvmd 4.188 mouse report_descriptor sha256s (it-03400 re-derived on 4.188).
    # Mode is classified by descriptor SHA (+ mouse count) per the #51 ruling —
    # NOT proto/subclass (the stock relative maker already reads 2/1) and NOT a
    # report_length constant. An unrecognised descriptor => observed=None => the
    # MCP fail-closes (safe). Pinned to 4.188; a kvmd bump that changes the
    # descriptor bytes makes observe() return None until these are refreshed.
    REL_SHAS = {
        "55c045b2daf5c91fd72fd8e1821e02a41c4118ea1badfdf4644e6db3d9970eed",  # relative, horizontal_wheel=false (ipad)
        "92155ddf022d4091f5e15eea5871107cd6ff7a4e6ada0ef931bd14b86c5632d0",  # relative, horizontal_wheel=true
    }
    ABS_SHAS = {
        "d9b93f5aa0cb2ab2f041d8c2da5f5b6c527e74192e2f1efa15c4844bec079621",  # absolute, horizontal_wheel=false
        "3a71a5a23705ee80a711e143d1242e34cb5d85592d4b5e6ac3f20bf8b9830a12",  # absolute, horizontal_wheel=true
    }

    def requested_mode():
        # The NEXT-BOOT mode = the boot-authoritative override kvmd-otg assembles
        # from: /var/lib/kvmd/hidmode.yaml, read LAST via override.d/90-hidmode.yaml.
        # This is the SINGLE source (#53) — there is no parallel marker to drift
        # from it. Classify by the topology keys the mode owns (mouse.absolute +
        # mouse_alt.device). `pikvm-hidmode set` writes this file ATOMICALLY and as
        # JSON (toJSON, a YAML subset), so json.load parses it. Absent / torn /
        # malformed / hand-edited-YAML => None => the drift diagnostic simply doesn't
        # fire (fail-closed: never a wrong next-boot mode). NOT the reported current
        # mode — that is observed_mode() (the assembled gadget); this only rides
        # along as `requested`, and requested != observed after settling = the box
        # is primed to boot into a different mode than it runs now (#44's signal).
        try:
            with open(OVERRIDE, "r") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            return None
        hid = (doc.get("kvmd") or {}).get("hid") or {}
        absolute = (hid.get("mouse") or {}).get("absolute")
        alt = (hid.get("mouse_alt") or {}).get("device")
        if absolute is False and alt == "":
            return "ipad"
        if absolute is True and alt:
            return "desktop"
        return None

    def observed_mode():
        # The ASSEMBLED gadget is ground truth. Classify the mouse HID functions
        # LINKED into the active config (configs/*/hid.* — NOT the functions/
        # pool, which keeps removed functions readable and would report a removed
        # mouse as present) by report_descriptor sha256:
        #   ipad    = exactly one RELATIVE mouse, no absolute (single relative).
        #   desktop = one ABSOLUTE (primary) + one RELATIVE (mouse_alt) — dual.
        # Returns None when the gadget is absent / mid-reassembly / an
        # unrecognised topology => the caller reports "settling", never a stale
        # or wrong mode.
        import glob, hashlib
        if not os.path.isdir(GADGET):
            return None  # torn down mid-switch — nothing to classify
        abs_n = rel_n = 0
        for link in glob.glob(GADGET + "/configs/*/hid.*"):
            if not os.path.islink(link):
                continue
            try:
                with open(os.path.join(os.path.realpath(link), "report_desc"), "rb") as fh:
                    sha = hashlib.sha256(fh.read()).hexdigest()
            except OSError:
                continue
            if sha in ABS_SHAS:
                abs_n += 1
            elif sha in REL_SHAS:
                rel_n += 1
        if abs_n == 0 and rel_n == 1:
            return "ipad"
        if abs_n == 1 and rel_n == 1:
            return "desktop"
        return None  # 0 mice / partial / unexpected => unknown (settling)

  '';
in
{
  # runtime-paths.nix, mcp-integration.nix, hidmode.nix: this module reads all
  # three — see module-list.nix / Round-2 Phase 2 for why every module now
  # imports its own declarers directly instead of relying on the aggregate.
  imports = [
    ./runtime-paths.nix
    ./mcp-integration.nix
    ./hidmode.nix
  ];

  options.services.pikvm.kvmd.hidMode.endpoint = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # On when both the hidMode apparatus AND the built-in MCP are enabled —
      # the endpoint is only useful if there's a switch to trigger and an MCP to
      # trigger it. Mirrors the hid-recovery endpoint's MCP-tied default.
      default = hidModeCfg.enable && config.services.pikvm.mcp.enabled;
      defaultText = lib.literalExpression "config.services.pikvm.kvmd.hidMode.enable && config.services.pikvm.mcp.enabled";
      example = true;
      description = ''
        The authenticated loopback HID-mode endpoint (GET /hidmode reads the
        current mode; POST /hidmode {"mode": …} switches it). Enabling it also
        wires PIKVM_HIDMODE_URL + a bearer token into the pikvm-mcp service env.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8083;
      description = "Loopback port the endpoint listens on (GET/POST /hidmode).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/pikvm-hidmode-token";
      description = ''
        Bearer token shared between this endpoint and the MCP server. When null
        (default) a random token is generated at first boot. Point at a
        sops/agenix secret to manage it yourself.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = hidModeCfg.enable;
          message = "services.pikvm.kvmd.hidMode.endpoint.enable requires services.pikvm.kvmd.hidMode.enable (the endpoint triggers the pikvm-hidmode@ units it provides).";
        }
      ];
    }
    # The polkit grant letting THIS endpoint's user start (only) the
    # pikvm-hidmode@ units. Lives here, not in hidmode.nix: "does an HTTP
    # endpoint exist to grant to" is an endpoint-level concern, and this
    # whole config block is already `lib.mkIf cfg.enable` — the grant only
    # needs to exist when the endpoint does, same condition hidmode.nix used
    # to gate on via cfg.endpoint.enable before this was relocated. Moving it
    # here (rather than having hidmode.nix import this file) avoids a genuine
    # A↔B module-graph cycle — this file already imports hidmode.nix — that
    # blows NixOS's module-collection stack; see hidmode.nix's config for the
    # full story (found by checks.module-self-sufficiency, Round-2 Phase 2).
    (mkUnitPrefixGrant {
      feature = "PiKVM HID-mode";
      comment = ''
        // PiKVM HID-mode: allow the loopback endpoint's user to start (only) the
        // mode-switch units.'';
      unitPrefix = "pikvm-hidmode@";
      triggerUser = hidModeCfg.triggerUser;
      triggerUserDeclared = config.users.users ? ${hidModeCfg.triggerUser};
    })
    (mkLoopbackEndpoint {
      description = "PiKVM HID-mode";
      name = "hidmode";
      user = hidModeCfg.triggerUser;
      port = cfg.port;
      tokenFile = cfg.tokenFile;
      tokenChannel = runtimePaths.hidmodeToken;
      mcpEnvChannel = runtimePaths.hidmodeMcpEnv;
      mcpEnvVar = "PIKVM_HIDMODE_TOKEN";
      handler = builtins.readFile ./hidmode-routes.py;
      inherit handlerEnv;
    })
    # Point the MCP server at us — via the always-declared write-side proxies
    # in mcp-integration.nix (services.pikvm.mcp.hidModeUrl/.forceTargetNull),
    # never services.pikvm-mcp.* directly: that option path only exists when
    # the upstream MCP module is imported, and a STRUCTURAL guard here (even
    # `lib.optional cfg.declared (...)`) hits real infinite recursion — see
    # mcp-integration.nix's header for the confirmed `nix eval --show-trace`
    # mechanism. A plain `mkIf` on the proxies below is safe: they're always
    # declared by this file regardless of MCP's presence, and
    # mcp-integration.nix alone forwards them into the real
    # services.pikvm-mcp.* when it's actually declared.
    (lib.mkIf config.services.pikvm.mcp.enabled {
      # URL-driven ⟺ target-independent: the MCP derives HID mode from this
      # endpoint's GET /hidmode, so force the flake wrapper's
      # `target = mkDefault "desktop"` to null → the module omits `--target`
      # (both-set is a runtime fail-fast the #46 module now rejects at eval).
      # Single source: hidModeUrl set here ⟺ target null here.
      services.pikvm.mcp.hidModeUrl = "http://127.0.0.1:${toString cfg.port}/hidmode";
      services.pikvm.mcp.forceTargetNull = true;
    })
  ]);
}
