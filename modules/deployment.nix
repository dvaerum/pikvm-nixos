# Per-deployment facts — the things that describe WHAT a box is plugged into
# and HOW it tracks this repo, as distinct from what board it's built on
# (hosts/boards/*.nix) or that it runs the PiKVM stack at all
# (hosts/profiles/appliance-stack.nix).
#
# This module defines the OPTION SURFACE only. It is deliberately inert here:
# `target.kind`/`target.alwaysAttached` don't yet drive hidmode.nix's
# fresh-install default or hid-latch-monitor.nix's healthyStates derivation —
# that consumption is Phase 4 (nixos-developer-system), which needs this
# surface to exist first. Until it lands, a host still sets the concrete
# downstream options directly (e.g. pikvm01.nix keeps its own
# `services.pikvm.kvmd.hidMode.default` and
# `services.pikvm.hidLatchMonitor.healthyStates` alongside `deployment.target`)
# — this module only wires `updateRef` through to `autoUpgrade.flake`, since
# that plumbing is simple, self-contained, and immediately useful.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.pikvm.deployment;
in
{
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
          (see docs/decisions/0001-ipad-hid-mode.md). Informational surface
          for now — see this file's header.
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
          `false` (most boxes get legitimately unplugged). Informational
          surface for now — see this file's header.
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
