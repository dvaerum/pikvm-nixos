# PiKVM runtime HID-mode switch (#51) — the config-layer + privileged-executor
# half. See docs/decisions/0001-ipad-hid-mode.md for the full rationale.
#
# Two selectable gadget shapes on ONE appliance, switchable at RUNTIME (no
# rebuild): `desktop` (absolute primary + relative mouse_alt — stock/faithful)
# and `ipad` (single relative mouse: mouse.absolute=false, mouse_alt.device="",
# horizontal_wheel=false — pikvm01's known-working shape). The mode lives in a
# MUTABLE /var file that kvmd's config layering reads LAST, so it wins over the
# declarative config; one control writes it and re-assembles the gadget.
#
# The AUTH half (a loopback token endpoint the MCP calls) is a separate module,
# hidmode-endpoint.nix — same split as hid-recovery{,-endpoint}.nix: privilege
# lives in the root units here; authentication lives in that endpoint. A polkit
# rule lets ONLY the endpoint's user start ONLY the pikvm-hidmode@ units.
#
# ⚠️ This feature ships ASSEMBLY-VERIFIED and NEVER behaviourally proven on the
# appliance — no node can currently demonstrate appliance iPad mode moves a real
# pointer (it-03400's gadget binds but the host doesn't enumerate it; the iPad
# rig's ground truth is pikvm01, stock Arch, not our appliance). See the ADR.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  kvmdCfg = config.services.pikvm.kvmd;
  cfg = kvmdCfg.hidMode;
  # Canonical contract in modules/runtime-paths.nix (Finding 3, Phase 2) — this
  # path was independently hardcoded here, in hidmode-set.sh, and in
  # hidmode-endpoint.nix before, silently driftable.
  overridePath = config.services.pikvm.runtimePaths.hidmodeOverride.path;

  mkUnitPrefixGrant = import ./lib/unit-prefix-grant.nix { inherit lib; };

  # The canonical per-mode override documents, in kvmd's override.d YAML shape
  # (YAML is a superset of JSON, so toJSON is a valid override). BOTH modes are
  # explicit on the topology keys so the mode is authoritative regardless of the
  # platform/user layers beneath it — desktop restores the stock absolute+alt
  # pairing; ipad forces the single-relative shape.
  desktopSettings.kvmd.hid = {
    mouse.absolute = true;
    mouse_alt.device = "/dev/kvmd-hid-mouse-alt";
  };
  ipadSettings.kvmd.hid = {
    mouse = {
      absolute = false;
      horizontal_wheel = false; # copy pikvm01's known-good shape (conservative; see ADR)
    };
    mouse_alt.device = ""; # empty ⇒ kvmd-otg assembles NO second mouse
  };
  desktopYaml = pkgs.writeText "hidmode-desktop.yaml" (builtins.toJSON desktopSettings);
  ipadYaml = pkgs.writeText "hidmode-ipad.yaml" (builtins.toJSON ipadSettings);

  # First-boot seed value (tmpfiles `C` copies it ONCE; never clobbered on
  # redeploy, so the runtime choice persists — see ADR). This override is the
  # SINGLE source of the mode (#53) — there is no separate marker to seed.
  defaultYaml = if cfg.default == "ipad" then ipadYaml else desktopYaml;

  # The privileged executor: `pikvm-hidmode {get|set <mode>}`. Store paths for
  # the two canonical docs are injected here so BOTH the local CLI and the
  # templated unit resolve them without an Environment= (the on-box debug path
  # works standalone).
  hidmodeExec = pkgs.writeShellApplication {
    name = "pikvm-hidmode";
    runtimeInputs = [
      pkgs.coreutils # install, cat, printf, chown, chmod
      config.systemd.package # systemctl
    ];
    text = ''
      HIDMODE_DESKTOP_YAML=${desktopYaml}
      HIDMODE_IPAD_YAML=${ipadYaml}
      HIDMODE_OVERRIDE_PATH=${overridePath}
    ''
    + builtins.readFile ./hidmode-set.sh;
  };

  # Which of the user's `settings` keys hidMode owns (and would silently
  # override, since the mode override at 90 is read after settings at 10).
  ownedKeyPaths = [
    [ "kvmd" "hid" "mouse" "absolute" ]
    [ "kvmd" "hid" "mouse" "horizontal_wheel" ]
    [ "kvmd" "hid" "mouse_alt" "device" ]
  ];
  userTouchedKeys = lib.filter (p: lib.hasAttrByPath p kvmdCfg.settings) ownedKeyPaths;

  # The built-in MCP's static `target` (desktop|ipad) can drift from the
  # appliance's HID mode — today, and at RUNTIME once the mode is switchable.
  # The single-source-of-truth fix is for the MCP to derive target from GET
  # /hidmode (routed to the MCP node as a #51 follow-up); until then, surface the
  # disagreement instead of letting it sit silent. Already null when the MCP
  # module isn't imported (services.pikvm.mcp.target's own default).
  mcpTarget = config.services.pikvm.mcp.target;
  mcpTargetDisagrees = mcpTarget != null && mcpTarget != cfg.default;
in
{
  imports = [
    # Retire the old build-time toggle LOUDLY — an existing config must fail at
    # eval with a pointer, never evaluate clean while quietly losing the setting.
    # This matters extra here: ipadCompat also patched kvmd/apps/otg/hid/mouse.py,
    # which was proven DEAD CODE (never executed under the relative iPad config),
    # so someone may believe it was doing something.
    (lib.mkRemovedOptionModule [ "services" "pikvm" "kvmd" "ipadCompat" "enable" ] ''
      iPad support is now the RUNTIME switch `services.pikvm.kvmd.hidMode`
      (default "desktop"; set hidMode.default = "ipad" for a fresh install, or
      switch a running box via the pikvm-hidmode control / the loopback endpoint
      — it persists in /var). The old ipadCompat additionally patched
      kvmd/apps/otg/hid/mouse.py to flip the ABSOLUTE mouse maker's USB interface
      fields; that patch was proven DEAD CODE (the absolute maker is never called
      under the relative iPad config) and has been dropped. Streamer tuning is no
      longer bundled with the HID mode — apply the known-good iPad values via
      services.pikvm.kvmd.settings. See docs/decisions/0001-ipad-hid-mode.md.
    '')
  ];

  options.services.pikvm.kvmd.hidMode = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.pikvm.otg.enable;
      defaultText = lib.literalExpression "config.services.pikvm.otg.enable";
      description = ''
        Enable the runtime HID-mode switch: select `desktop` (absolute dual
        mouse — stock) or `ipad` (single relative mouse) at runtime, without a
        rebuild, persisting across reboot and redeploy. Only meaningful with the
        OTG gadget (defaults to `services.pikvm.otg.enable`).

        ⚠️ This ships ASSEMBLY-VERIFIED and NEVER behaviourally proven on the
        appliance: the gadget re-assembles to the selected shape, but no node on
        this project can currently demonstrate that appliance iPad mode makes a
        real iPad move a pointer (cabling dependency — see
        docs/decisions/0001-ipad-hid-mode.md).
      '';
    };

    default = lib.mkOption {
      type = lib.types.enum [ "desktop" "ipad" ];
      default = "desktop";
      description = ''
        The FRESH-INSTALL mode. Seeds the mutable /var state exactly once; it is
        NOT re-applied on redeploy, so changing this on an already-provisioned
        box does not move it (the runtime choice persists). Fresh-install default
        is `desktop`, faithful to stock PiKVM.
      '';
    };

    triggerUser = lib.mkOption {
      type = lib.types.str;
      default = "pikvm-hidmode";
      description = ''
        The system user granted (via polkit) permission to `systemctl start
        pikvm-hidmode@<mode>.service` — and nothing else. This is the loopback
        endpoint's dedicated user; it holds the authentication boundary while
        privilege stays in the root units here. The endpoint module creates it.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = hidmodeExec;
      defaultText = lib.literalExpression "the pikvm-hidmode executor";
      readOnly = true;
      description = "The pikvm-hidmode executor (also the pikvm-hidmode@ ExecStart).";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.endpoint.enable (mkUnitPrefixGrant {
      feature = "PiKVM HID-mode";
      comment = ''
        // PiKVM HID-mode: allow the loopback endpoint's user to start (only) the
        // mode-switch units.'';
      unitPrefix = "pikvm-hidmode@";
      triggerUser = cfg.triggerUser;
      triggerUserDeclared = config.users.users ? ${cfg.triggerUser};
    }))
    (lib.mkIf (kvmdCfg.enable && cfg.enable) {
    # Seed the mutable override ONCE (C, not C+ → never clobbered on redeploy).
    # /var/lib/kvmd itself is created by the kvmd module. This single file is the
    # source of the mode (#53); pikvm-hidmode rewrites it atomically.
    systemd.tmpfiles.rules = [
      "C ${overridePath} 0644 kvmd kvmd - ${defaultYaml}"
      # #53 fast-follow: remove the retired plain-text marker on activation. #53
      # collapsed the mode to the boot-authoritative yaml above and nothing reads
      # the marker anymore, but a box UPGRADED from the pre-#53 scheme still carries
      # /var/lib/kvmd/hidmode as an inert leftover. Declaratively clear it so a
      # future maintainer doesn't find a dead file that looks like it should matter.
      # `r` = remove-if-present (a no-op on a fresh install; idempotent).
      "r /var/lib/kvmd/hidmode - - - -"
    ];

    # The LAST-read override.d drop-in (90- sorts after 00/10, so the mode wins)
    # is a GENERATION-MANAGED symlink to the mutable /var content — deliberately
    # environment.etc, NOT a tmpfiles symlink. This is the ROLLBACK FIX: env.etc
    # puts it in every #51 generation's /etc closure (so the mode still persists
    # across #51→#51 UPGRADES), but NixOS etc-activation REMOVES entries not in
    # the current generation — so rolling back to a PRE-#51 generation drops this
    # symlink, the override stops applying, and the box reverts to STOCK. A
    # tmpfiles symlink would create-but-never-remove it, stranding the mode live
    # with no control surface (units/endpoint gone). Property: persisted mode is
    # INERT without its controller; safe rollback = revert-to-stock (faithfulness).
    # The /var content persists but is simply no longer read once the link is gone.
    environment.etc."kvmd/override.d/90-hidmode.yaml".source = overridePath;

    # Templated root oneshot: one instance per mode. %i (desktop|ipad) is passed
    # straight to the executor, which validates it.
    systemd.services."pikvm-hidmode@" = {
      description = "PiKVM HID mode switch: %i";
      # Runs as root: installs /var/lib/kvmd state (kvmd-owned) and restarts
      # kvmd-otg + kvmd. Not wantedBy anything — started on demand only.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${hidmodeExec}/bin/pikvm-hidmode set %i";
      };
    };

    # On-box debug CLI: `pikvm-hidmode {get|set <mode>}` (set needs root).
    environment.systemPackages = [ hidmodeExec ];

    # 90-hidmode (read last) WINS over the user's settings (10). Warn loudly at
    # eval if `settings` sets a key hidMode owns, so a stray value that hidMode
    # silently overrides becomes a readable message instead of a confusing no-op.
    warnings =
      lib.optional (userTouchedKeys != [ ]) ''
        services.pikvm.kvmd.settings sets ${
          lib.concatMapStringsSep ", " (lib.concatStringsSep ".") userTouchedKeys
        }, but services.pikvm.kvmd.hidMode OWNS hid.mouse.absolute / hid.mouse.horizontal_wheel / hid.mouse_alt.device. hidMode's override (override.d/90) is read AFTER your settings (override.d/10) and WINS, so your value is ignored. Set the mode via hidMode instead, or set services.pikvm.kvmd.hidMode.enable = false to hand these keys back to `settings`.
      ''
      ++ lib.optional mcpTargetDisagrees ''
        services.pikvm-mcp.target = "${mcpTarget}" disagrees with services.pikvm.kvmd.hidMode.default = "${cfg.default}". The appliance owns the HID mode (single source of truth); a static MCP target can drift from it — and after the runtime switch lands, they can disagree at runtime, which is worse. Make them match, or (the real fix, tracked as a #51 follow-up) let the MCP derive its target from the appliance's GET /hidmode instead of declaring it.
      '';
    })
  ];
}
