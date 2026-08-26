# pikvm01 — the WB-kiosk Pi4B whose KVM target is an iPad. TEST infrastructure,
# NOT production (georg, 2026-08-23: "pikvm01.bb.vcamp.dk is used in our test
# setup (not production)" — corrects an earlier mislabel; don't re-introduce it).
#
# Identical hardware/stack to the generic `rpi4` target (hosts/default.nix builds
# this config as `rpi4` modules + this file), so it inherits the vendor kernel,
# disko layout, direct-kernel boot, and the whole PiKVM stack. It differs from
# `rpi4` in one deployment fact, all because this specific box drives an iPad
# (relative/single-mouse HID) and is permanently cabled, rather than the
# desktop/absolute + intermittently-cabled target the shared `rpi4` config
# stays faithful to (e.g. it-03400's patient-monitor-cabled appliance):
# `services.pikvm.deployment.target`. Everything downstream of that one fact —
# the fresh-install HID mode (modules/hidmode.nix) and the HID-latch monitor's
# narrowed healthy-state set (modules/hid-latch-monitor.nix, catching the
# VBUS-latch fault mode a permanently-cabled target can also fail with) — now
# DERIVES from it (Phase 4); this file states the fact once instead of also
# setting each downstream option by hand.
#
# Keeping this as a distinct host (rather than flipping the shared `rpi4`
# default) is the declarative, drift-free answer: it leaves `rpi4` — and every
# other Pi4 that tracks it, like it-03400 — untouched at its stock defaults,
# and it gives pikvm01 a self-update ref that carries this box-specific one.
#
# NOTE: this kiosk's KVM target is an iPad (relative-only HID), but the MCP no
# longer takes a static `services.pikvm-mcp.target`. Post-#46 the MCP derives
# its HID mode from the appliance's GET /hidmode (wired as
# services.pikvm-mcp.hidModeUrl in modules/hidmode-endpoint.nix, which also sets
# target = null) and is stateless about mode — the appliance's runtime hidMode
# switch + its persisted marker is the single source of truth. A static target
# here would be redundant and, with the URL present, an eval error (the #46
# module rejects both-set). The iPad default is expressed via
# services.pikvm.deployment.target.kind below, not a static MCP target.
{ ... }:
{
  # Deployment facts (Phase 4, modules/deployment.nix): this kiosk's target is
  # an iPad, and it's permanently cabled — never legitimately unplugged. Both
  # downstream consumers pick these up as their own defaults:
  #   - modules/hidmode.nix: fresh-install HID mode seeds to "ipad" instead of
  #     the stock "desktop" default (the post-swap "HID came up absolute" bug
  #     on the pikvm-nixos migration this originally fixed). Per
  #     modules/hidmode.nix, this seeds the mutable /var state ONCE on first
  #     boot and is NOT re-applied on redeploy — the runtime hidMode switch +
  #     its persisted yaml remain the single source of truth (#53) once the
  #     box is provisioned. So this fixes the fresh-flash default only; it
  #     does not fight a deliberate runtime switch on an already-running box.
  #   - modules/hid-latch-monitor.nix: healthyStates narrows to just
  #     ["configured"] (default also accepts "not attached", since most boxes
  #     get legitimately unplugged) — docs/decisions/0003-hid-latch-monitor.md
  #     names this box by name as needing that narrowing, at the correct
  #     tradeoff for it: a genuine iPad unplug now also fires the alarm.
  services.pikvm.deployment.target = {
    kind = "ipad";
    alwaysAttached = true;
  };

  # Self-update from THIS host's config, not `#rpi4`. hosts/rpi4.nix sets
  # deployment.updateRef to `#rpi4` with mkDefault; a plain assignment here
  # wins, so pikvm01 tracks the ipad-default configuration on its weekly
  # auto-upgrade (deployment.nix feeds this through to autoUpgrade.flake).
  services.pikvm.deployment.updateRef = "#pikvm01";

  # Keep ustreamer running permanently instead of kvmd's default on-demand
  # idle-stop (~10s after the last video client disconnects, ~3% CPU saved).
  # This box's video feed is polled repeatedly by short-lived MCP clients
  # (screenshots between iPad-rig test runs), so the idle-stop/cold-start
  # cycle costs reconnect latency + occasional flakiness on every poll — the
  # exact tradeoff kvmd's own `streamer.forever` option exists for. This was
  # set by hand in pikvm01's old stock-Arch override.yaml (documented in
  # pikvm_mcp_server's docs/troubleshooting/pikvm-server-changes.md, applied
  # 2026-04-26) and silently lost in the 2026-08-23 SD-swap to pikvm-nixos —
  # restoring it declaratively here via the generic settings escape hatch
  # (modules/kvmd.nix's `services.pikvm.kvmd.settings`, same mechanism as
  # desired_fps/atx.type/msd.type elsewhere) means it survives every future
  # re-image instead of depending on a manual edit that can go missing again.
  services.pikvm.kvmd.settings.kvmd.streamer.forever = true;
}
