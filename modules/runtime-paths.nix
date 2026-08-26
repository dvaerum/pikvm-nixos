# The ONE place this flake declares its shared runtime-path contract — every
# /run|/var/lib artifact + configfs name that more than one module reads or
# writes, bundled with its expected mode/owner/producing-unit, so consumers
# derive from ONE canonical value instead of hand-matching path/mode/owner
# literals that can silently drift out of sync across files. Confirmed this
# WAS drifting before this module existed (Finding 3, Phase 2): the hidmode
# token path alone was independently hardcoded as the literal string
# "/run/pikvm-hidmode/token" in THREE separate files (hidmode-endpoint.nix,
# which owns it; hidmode-web.nix, which reads it; and would silently miss a
# future rename in either).
#
# Read-only/internal throughout: nothing here is meant to be end-user
# configurable — these are INTERNAL WIRING CONTRACTS between our own modules,
# not a public option surface. A consumer that needs a DIFFERENT path is
# consuming the wrong abstraction; change it here, once.
{ config, lib, ... }:
let
  hidModeCfg = config.services.pikvm.kvmd.hidMode;
  hidRecoveryCfg = config.services.pikvm.hidRecovery;

  # Each "channel" bundles the three facts a consumer or a test actually needs:
  #   path          — the file/directory/configfs path itself.
  #   mode          — expected octal permission bits the producer lands the
  #                   artifact with, or null when not file-mode-meaningful.
  #   owner         — "user" or "user:group" the artifact is expected to be
  #                   owned by, or null when not meaningful/not fixed (a
  #                   channel whose real owner is itself a configurable
  #                   triggerUser derives it dynamically below, rather than
  #                   hardcoding a guess here).
  # Documents the contract and lets a VM test assert the RIGHT thing —
  # docs/decisions/0003-hid-latch-monitor.md's "verify by stat, not a 200"
  # gating note: an endpoint returning 200 only proves a SAME-USER (root, in
  # every test here) read succeeded, never the artifact's real mode/owner as
  # seen by the actual cross-user consumer — only a direct `stat` on `path`
  # proves that.
  #
  # (A fourth field, `producingUnit`, existed here through Phase 3 but was
  # removed for having zero consumers and no proposed one — see
  # docs/FUTURE-WORK.md if a real consumer shows up later.)
  # NOTE: none of these three fields are individually `readOnly` — `readOnly`
  # requires EXACTLY one definition, but every channel option below provides
  # its value as a whole-attrset OUTER `default`, which the submodule
  # machinery merges in as a definition of these inner fields ON TOP OF
  # whatever default this type itself declares — so an inner `readOnly` here
  # conflicts with itself (confirmed via a real `nix eval`: "option
  # ...hidLatchStatus.mode is read-only, but it's set multiple times").
  # `readOnly = true` on the OUTER channel option (below) is what actually
  # matters — it stops a CONSUMER from overriding the whole bundle; that's
  # unaffected by these inner fields being plain.
  channelType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "The filesystem (or configfs) path for this channel.";
      };
      mode = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Expected octal permission bits (e.g. \"0644\"), or null.";
      };
      owner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''"user" or "user:group" the artifact should be owned by, or null.'';
      };
    };
  };
in
{
  options.services.pikvm.runtimePaths = {
    hidLatchStatus = lib.mkOption {
      type = channelType;
      internal = true;
      readOnly = true;
      default = {
        path = "/run/pikvm-hid-latch/status.json";
        mode = "0644";
        owner = "root:root";
      };
      description = ''
        The HID-latch monitor's atomically-written status.json, served by the
        HID-recovery loopback endpoint at GET /hid-recovery/latch-status. Must
        be world-readable (0644) — the endpoint runs as a different user than
        the monitor. See docs/decisions/0003-hid-latch-monitor.md.
      '';
    };

    hidmodeToken = lib.mkOption {
      type = channelType;
      internal = true;
      readOnly = true;
      default = {
        path = "/run/pikvm-hidmode/token";
        mode = "0640";
        owner = "root:${hidModeCfg.triggerUser}";
      };
      description = ''
        The bearer token shared between the hidmode loopback endpoint
        (modules/hidmode-endpoint.nix) and its consumers (the MCP server, the
        443 dashboard proxy in hidmode-web.nix).
      '';
    };

    hidmodeMcpEnv = lib.mkOption {
      type = channelType;
      internal = true;
      readOnly = true;
      default = {
        path = "/run/pikvm-hidmode/mcp.env";
        mode = "0600";
        owner = "root:root";
      };
      description = "EnvironmentFile injecting PIKVM_HIDMODE_TOKEN into services.pikvm-mcp.";
    };

    hidRecoveryToken = lib.mkOption {
      type = channelType;
      internal = true;
      readOnly = true;
      default = {
        path = "/run/pikvm-hid-recovery/token";
        mode = "0640";
        owner = "root:${hidRecoveryCfg.triggerUser}";
      };
      description = ''
        The bearer token shared between the HID-recovery loopback endpoint
        (modules/hid-recovery-endpoint.nix) and the MCP server.
      '';
    };

    hidRecoveryMcpEnv = lib.mkOption {
      type = channelType;
      internal = true;
      readOnly = true;
      default = {
        path = "/run/pikvm-hid-recovery/mcp.env";
        mode = "0600";
        owner = "root:root";
      };
      description = "EnvironmentFile injecting PIKVM_HID_RECOVERY_TOKEN into services.pikvm-mcp.";
    };

    hidmodeOverride = lib.mkOption {
      type = channelType;
      internal = true;
      readOnly = true;
      default = {
        path = "/var/lib/kvmd/hidmode.yaml";
        mode = null; # written by the pikvm-hidmode CLI at an arbitrary point in time, not one fixed producing unit
        owner = null;
      };
      description = ''
        The boot-authoritative HID-mode override file kvmd-otg reads LAST (via
        override.d/90-hidmode.yaml) — the single source of truth for next-boot
        HID mode (#53). Written by the `pikvm-hidmode set` CLI, not a systemd
        service, so mode/owner are deliberately null here.
      '';
    };

    otgGadgetName = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = "kvmd";
      description = ''
        The configfs USB gadget name kvmd-otg assembles under
        /sys/kernel/config/usb_gadget/<name>. A bare string, not a channel
        bundle — there's no file mode/owner/producing-unit concept for a
        configfs gadget name itself; consumers derive a real path by
        interpolating it onto "/sys/kernel/config/usb_gadget/".
      '';
    };
  };
}
