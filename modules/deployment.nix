# Per-deployment facts — the things that describe WHAT a box is plugged into
# and HOW it tracks this repo, as distinct from what board it's built on
# (hosts/boards/*.nix) or that it runs the PiKVM stack at all
# (hosts/profiles/appliance-stack.nix).
#
# This module defines the OPTION SURFACE and is consumed downstream (Phase 4):
# `target.kind` is hidmode.nix's `hidMode.default`'s DEFAULT (a host states its
# target once, here, instead of separately picking a fresh-install HID mode);
# `target.alwaysAttached` is hid-latch-monitor.nix's `healthyStates`'s DEFAULT
# (true narrows to `[ "configured" ]`, catching the VBUS-latch fault mode; false
# — most boxes, legitimately unplugged sometimes — keeps `"not attached"`
# healthy too). A host only needs to set `deployment.target` once; both
# downstream defaults follow. Overriding one of the two consuming options
# directly (without also updating the matching `deployment.target` field) is
# still possible — mkDefault leaves room for it — but each consumer warns if
# its own value ends up disagreeing with what `deployment.target` states, so
# an accidental one-sided override doesn't sit silent. `updateRef` remains
# simple, self-contained plumbing straight into `autoUpgrade.flake`.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.pikvm.deployment;
in
{
  # Self-sufficiency: this module's own config unconditionally targets
  # services.pikvm.autoUpgrade.flake (below) regardless of its mkIf's
  # condition value — NixOS type-checks a defined option path against the
  # declared option tree independently of which branch wins, so that option
  # must exist wherever THIS module is imported. Import the module that
  # declares it rather than relying on every consumer to have already done
  # so ahead of us.
  imports = [ ./system/auto-upgrade.nix ];

  options.services.pikvm.deployment = {
    target = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "desktop"
          "ipad"
        ];
        default = "desktop";
        description = ''
          What this box's HID output is plugged into. `desktop` is the stock/
          faithful shape (absolute primary mouse + relative mouse_alt);
          `ipad` is the single-relative shape iPadOS's HID parser accepts
          (see docs/decisions/0001-ipad-hid-mode.md). Feeds
          `services.pikvm.kvmd.hidMode.default` as its own default — see this
          file's header.
        '';
      };

      alwaysAttached = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this box's target is PERMANENTLY cabled, so a genuinely
          unplugged gadget ("not attached") is never a legitimate state and
          can safely be treated as unhealthy — the fact
          hid-latch-monitor.nix's healthy-state derivation needs, per ADR
          0003's own framing ("target-ALWAYS-attached deployment"). Default
          `false` (most boxes get legitimately unplugged). Feeds
          `services.pikvm.hidLatchMonitor.healthyStates` as its own default —
          see this file's header.
        '';
      };
    };

    updateRef = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "#it-03400";
      description = ''
        This box's own flake-output fragment (e.g. `"#it-03400"`), fed into
        `services.pikvm.autoUpgrade.flake` as
        `"github:dvaerum/pikvm-nixos''${updateRef}"` via `mkDefault` so a host
        can still override `autoUpgrade.flake` directly if it needs a
        non-standard update source. `null` (default) leaves
        `autoUpgrade.flake` at its own module default.
      '';
    };
  };

  config = lib.mkIf (cfg.updateRef != null) {
    services.pikvm.autoUpgrade.flake = lib.mkDefault "github:dvaerum/pikvm-nixos${cfg.updateRef}";
  };
}
