# The ONE place this flake talks to the OPTIONAL upstream MCP module
# (`services.pikvm-mcp`, from the separate pikvm_mcp_server flake input).
# `nixosModules.pikvm` is documented (flake.nix) as independently composable
# WITHOUT `nixosModules.mcp-server` — but several modules here (hid-latch-
# monitor, hid-recovery-endpoint, hidmode-endpoint, hidmode, nginx) need to
# know whether the MCP is present, read a few of its settings, and (two of
# them) inject a couple of values INTO it.
#
# A bare `config.services.pikvm-mcp.foo` throws "The option `services.pikvm-mcp'
# does not exist" at eval time when that module isn't imported — REGARDLESS of
# any `mkIf`/`or` wrapping the access, because NixOS's module system
# type-checks every DEFINED option path against the declared option tree
# independently of which mkIf branch wins the merge. This broke
# `nixosModules.pikvm` standalone (confirmed via real `nix eval`).
#
# READS (nginx.nix, hidmode.nix, hid-latch-monitor.nix, and the `enable`
# DEFAULTS in hid-recovery-endpoint.nix/hidmode-endpoint.nix) go through the
# read-only options below — `declared`/`enabled`/`package`/`address`/`port`/
# `target` — which all degrade to a safe default when MCP isn't declared. This
# part matches the obvious design and is safe: these options are ALWAYS
# declared (by this module) regardless of MCP's presence, so reading them
# never needs an `or` escape hatch, and using their VALUE to prioritize an
# already-existing option elsewhere (a plain `mkIf`) never risks the option
# not existing.
#
# WRITES (hid-recovery-endpoint.nix wants to set services.pikvm-mcp.extraEnv;
# hidmode-endpoint.nix wants to set .hidModeUrl and force .target to null) are
# NOT done directly by those modules, even behind a guard — see below for why
# that specific shape is unsafe, confirmed by a real `nix eval --show-trace`,
# not theorized. Instead those modules write to the always-declared PROXY
# options in this file (`extraEnv`, `hidModeUrl`, `forceTargetNull` —
# unconditionally, no guard needed, since these options always exist), and
# THIS module alone forwards them into the real `services.pikvm-mcp.*` when
# it's actually declared.
#
# ⚠️ WHY A CONSUMING MODULE CAN'T GATE ITS OWN WRITE, even via
# `lib.optional cfg.declared (lib.mkIf cfg.enabled { services.pikvm-mcp.foo =
# …; })`: NixOS's `_module.freeformType`/"checkUnmatched" machinery
# (lib/modules.nix) has to enumerate every module's DEFINED PATHS — including
# whether a `lib.optional cond (...)` block is even PRESENT in a module's
# `config` output — every time `config.system.build.toplevel` is forced. If
# `cond` is itself a regular OPTION's config VALUE (`config.services.pikvm.mcp
# .declared`, or even a `_module.args` value that's ITSELF assigned from
# inside a `config` block, which is still part of the same fixpoint), computing
# `cond` requires re-entering that SAME path enumeration, which requires
# `cond` again — infinite recursion, not a false positive. The escape is
# structural: THIS module's own `declared` (a plain `let`-bound value, from
# `options.services ? pikvm-mcp` — option DECLARATION, a separate/earlier
# phase, never round-tripped through any module's config value) gates only
# THIS module's own forwarding block. Nothing outside this file ever needs to
# know MCP's declaration state to decide whether ITS OWN config contribution
# exists — every other module's write target here is unconditionally real.
{ config, options, lib, ... }:
let
  declared = options.services ? pikvm-mcp;
  # Only forced when `declared` — `if`/`&&` are lazy on the untaken branch, so
  # this never dereferences a nonexistent `config.services.pikvm-mcp`.
  mcp = if declared then config.services.pikvm-mcp else null;
  cfg = config.services.pikvm.mcp;
in
{
  options.services.pikvm.mcp = {
    declared = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      default = declared;
      description = "Whether services.pikvm-mcp (the upstream MCP module) is imported at all.";
    };

    enabled = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      default = declared && mcp.enable;
      description = "declared && services.pikvm-mcp.enable — false when not declared.";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      internal = true;
      readOnly = true;
      default = if declared then mcp.package else null;
      description = "services.pikvm-mcp.package, or null when not declared.";
    };

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      internal = true;
      readOnly = true;
      default = if declared then mcp.address else null;
      description = "services.pikvm-mcp.address, or null when not declared.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      internal = true;
      readOnly = true;
      default = if declared then mcp.port else null;
      description = "services.pikvm-mcp.port, or null when not declared.";
    };

    target = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "ipad" "desktop" ]);
      internal = true;
      readOnly = true;
      default = if declared then mcp.target else null;
      description = "services.pikvm-mcp.target, or null when not declared.";
    };

    # --- Write-side proxies: always declared, safe for any module to set
    # unconditionally. Forwarded into the real services.pikvm-mcp.* below,
    # ONLY when declared, ONLY from this file. Ignored (harmlessly) when MCP
    # isn't declared — a contributing module doesn't need to know or care.
    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      default = { };
      description = ''
        Extra services.pikvm-mcp environment variables other modules want
        injected, keyed by var name (attrsOf merges cleanly across modules —
        each contributes different keys, matching how services.pikvm-mcp's
        own extraEnv is used elsewhere).
      '';
    };

    hidModeUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      internal = true;
      default = null;
      description = "Forwarded into services.pikvm-mcp.hidModeUrl when declared.";
    };

    forceTargetNull = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      default = false;
      description = ''
        When true, forces services.pikvm-mcp.target = null (mkForce) when
        declared — set by hidmode-endpoint.nix, whose hidModeUrl derive-mode
        is mutually exclusive with a declared target (see that module).
      '';
    };
  };

  # `lib.optionalAttrs declared (...)` — the attrset-context equivalent of
  # `lib.optional` on a list — NOT `lib.mkIf declared (...)`. A bare `mkIf`
  # still requires `services.pikvm-mcp.*` to exist for type-checking
  # regardless of the condition's value (that IS the original Phase-1 bug);
  # `optionalAttrs` returns a literal `{}` when `declared` is false, so this
  # module contributes NOTHING to `services.pikvm-mcp.*` at all in that case
  # — nothing to type-check. `declared` here is the local, non-config-value
  # let-binding above, never round-tripped through `config.*` — that's what
  # keeps THIS safe (see the file header for the cycle a config-value version
  # of this same idea hits).
  #
  # The THREE inner forwards are ALL bare `mkIf` — deliberately, NOT
  # `optionalAttrs` — even though `services.pikvm-mcp.*` genuinely exists
  # here (we're already inside the `declared = true` branch). A SECOND real
  # infinite-recursion cycle (confirmed via `nix eval --show-trace`) came
  # from using `optionalAttrs (cfg.extraEnv != { }) { ... }` for the extraEnv
  # forward: `optionalAttrs`'s returned attrset is EITHER `{}` OR the real
  # keys — the key SET itself depends on the condition — so NixOS's
  # checkUnmatched machinery (which must enumerate every module's defined
  # paths, `lib/modules.nix` ~283-306) has to force `cfg.extraEnv != { }`
  # just to know this module's own output shape. `cfg.extraEnv` reads
  # `config.services.pikvm.mcp.extraEnv` — the EXACT option that same
  # enumeration pass is concurrently trying to resolve (to collect all
  # modules' definitions of it) — a direct self-reference. `mkIf`, by
  # contrast, always returns the SAME fixed `{ _type = "if"; condition;
  # content; }` shape regardless of the condition's value, so enumerating
  # this module's keys never needs to force the condition — safe. An empty
  # `extraEnv = { }` forwarded via `mkIf true` merges harmlessly (attrsOf
  # merge of `{ }` is a no-op), so there's no correctness reason to gate it
  # on non-emptiness in the first place.
  config = lib.optionalAttrs declared (lib.mkMerge [
    (lib.mkIf (cfg.extraEnv != { }) {
      services.pikvm-mcp.extraEnv = cfg.extraEnv;
    })
    (lib.mkIf (cfg.hidModeUrl != null) {
      services.pikvm-mcp.hidModeUrl = cfg.hidModeUrl;
    })
    (lib.mkIf cfg.forceTargetNull {
      services.pikvm-mcp.target = lib.mkForce null;
    })
  ]);
}
