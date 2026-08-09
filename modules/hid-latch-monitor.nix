# PiKVM HID-latch monitor — a REPORT-ONLY systemd service that watches the
# appliance's OWN local UDC and detects a latched/thrashing HID death that unit
# status cannot see (the ~6.6-day silent-death class: kvmd/kvmd-otg `active`,
# NRestarts=0, gadget gone). See docs/decisions/0003-hid-latch-monitor.md.
#
# It runs the af8d7d2 latch classifier (shipped in pikvm-mcp-server) over a LOCAL
# source: the SSH transport is gone; the box reads its own /sys. The composite
# health signal is `function`-non-empty (gadget BOUND) AND state-in-set — NOT
# `state` alone, which is blind to a full teardown on an uncabled box (that reads
# "not attached" whether bound-and-healthy or completely unbound). unbound ⇒
# broken always ⇒ the monitor catches the #48 gadget-never-bound case too.
#
# Alert channel: JSONL to journald + an atomically-written status.json that the
# loopback hid-recovery-endpoint serves at GET /hid-recovery/latch-status (→ the
# MCP /mcp health_check + the 443 dashboard). The on-box dead-man is systemd
# Restart (crash) + the status file's advancing lastSampleAt (hang) — no external
# observer. Report-only in v1; auto-recovery (latched → pikvm-hid-recover@udc-rebind,
# whose oneshot already ships) is a deferred v2.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.hidLatchMonitor;
  statusDir = "/run/pikvm-hid-latch";
  statusPath = "${statusDir}/status.json";
in
{
  options.services.pikvm.hidLatchMonitor = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.pikvm.otg.enable;
      defaultText = lib.literalExpression "config.services.pikvm.otg.enable";
      description = ''
        Enable the report-only HID-latch monitor. Samples the appliance's own
        local UDC (gadget bound-ness + state) and fires when HID is latched dead
        — the failure class that leaves systemd green. Defaults to
        `services.pikvm.otg.enable` (there must be a gadget/UDC to watch).
        Report-only: no auto-recovery in v1 (the pikvm-hid-recover@ oneshots are a
        deferred v2). See docs/decisions/0003-hid-latch-monitor.md.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = config.services.pikvm-mcp.package or pkgs.pikvm-mcp-server;
      defaultText = lib.literalExpression "config.services.pikvm-mcp.package";
      description = ''
        The package providing `bin/pikvm-hid-latch-monitor`. Defaults to the
        built-in MCP server package (the classifier + local source ship there).
      '';
    };

    healthyStates = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "configured"
        "not attached"
      ];
      description = ''
        The UDC `state` values considered healthy WHILE THE GADGET IS BOUND.
        Default accepts a configured target AND an unplugged one ("not attached")
        — bound-ness is the real gate, so a legitimate unplug does not false-fire.
        Set to just `[ "configured" ]` on a target-ALWAYS-attached deployment to
        also detect the VBUS-latch second fault mode (at the cost of firing on a
        legitimate unplug — hence opt-in). See ADR 0003.
      '';
    };

    gadget = lib.mkOption {
      type = lib.types.str;
      default = "kvmd";
      description = ''
        The configfs USB gadget name — the source corroborates bound-ness with
        `/sys/kernel/config/usb_gadget/<gadget>/UDC` (ENOENT there ⇒ BROKEN, never
        a source error: the #48 case where the gadget dir is never created).
        `function` remains the field of record.
      '';
    };

    reenumPattern = lib.mkOption {
      type = lib.types.str;
      default = "bound driver configfs-gadget";
      description = ''
        The `journalctl -k -b` grep pattern counted as gadget re-enumeration
        (bind) events — a monotonic bind counter that separates `latched`
        (flatline) from `thrashing` (climbing). This is the appliance dwc2
        GADGET-side line, NOT pikvm01's host-side "new device is high-speed". The
        counter is read boot-scoped (`-b`) ONLY: the appliance has no RTC, so a
        time-windowed count silently under-counts binds and would misclassify
        thrashing as latched (wrong recovery rung).
      '';
    };

    udc = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fe980000.usb";
      description = ''
        The UDC name to watch. null (default) = the single UDC discovered under
        `/sys/class/udc` (matches modules/hid-recover.sh's find_udc).
      '';
    };
  };

  config = lib.mkIf (config.services.pikvm.otg.enable && cfg.enable) {
    systemd.services.pikvm-hid-latch-monitor = {
      description = "PiKVM HID-latch monitor (report-only)";
      wantedBy = [ "multi-user.target" ];
      # Start after kvmd-otg has attempted assembly — but deliberately NOT
      # Requires=/BindsTo: the monitor must keep running to observe kvmd-otg
      # FAILING to keep HID up (the whole point).
      after = [ "kvmd-otg.service" ];
      path = [ config.systemd.package ]; # journalctl for the bind counter
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/pikvm-hid-latch-monitor";
        # The dead-man: a crash is auto-restarted; a hang is caught by the status
        # file's stale lastSampleAt (read by health_check).
        Restart = "always";
        RestartSec = 5;
        # The status file the loopback endpoint serves. RuntimeDirectory is
        # 0755 so the (different-user) endpoint can traverse in and read the
        # world-readable status.json. UMask=0022 makes the monitor's atomic
        # write land 0644 REGARDLESS of the inherited default — the endpoint runs
        # as a different user, so the cross-user read must not depend on systemd's
        # default umask staying 0022.
        RuntimeDirectory = "pikvm-hid-latch";
        RuntimeDirectoryMode = "0755";
        UMask = "0022";
        # Report-only reader: runs as root for `journalctl -k` + the configfs
        # corroboration read, but hardened + read-only everywhere except its own
        # /run status dir. It performs NO privileged writes (recovery is v2).
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ statusDir ];
        LockPersonality = true;
        RestrictNamespaces = true;
      };
      environment = {
        PIKVM_LATCH_SOURCE = "local";
        PIKVM_LATCH_GADGET = cfg.gadget;
        PIKVM_LATCH_REENUM_PATTERN = cfg.reenumPattern;
        PIKVM_LATCH_HEALTHY_STATE = lib.concatStringsSep "," cfg.healthyStates;
        PIKVM_LATCH_STATUS_PATH = statusPath;
      }
      // lib.optionalAttrs (cfg.udc != null) { PIKVM_LATCH_UDC = cfg.udc; };
    };
  };
}
