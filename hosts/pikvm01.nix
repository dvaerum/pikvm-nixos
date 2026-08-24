# pikvm01 — the WB-kiosk Pi4B whose KVM target is an iPad. TEST infrastructure,
# NOT production (georg, 2026-08-23: "pikvm01.bb.vcamp.dk is used in our test
# setup (not production)" — corrects an earlier mislabel; don't re-introduce it).
#
# Identical hardware/stack to the generic `rpi4` target (hosts/default.nix builds
# this config as `rpi4` modules + this file), so it inherits the vendor kernel,
# disko layout, direct-kernel boot, and the whole PiKVM stack. It differs from
# `rpi4` in three per-box ways, all because this specific box drives an iPad
# (relative/single-mouse HID) and is permanently cabled, rather than the
# desktop/absolute + intermittently-cabled target the shared `rpi4` config
# stays faithful to (e.g. it-03400's patient-monitor-cabled appliance):
#
#   1. the FRESH-INSTALL HID mode is iPad, not the stock desktop default;
#   2. it self-updates from its OWN config attribute, not `#rpi4`; and
#   3. the HID-latch monitor's healthy-state set is narrowed to catch the
#      VBUS-latch fault mode, since this box is never legitimately unplugged.
#
# Keeping this as a distinct host (rather than flipping the shared `rpi4`
# default) is the declarative, drift-free answer: it leaves `rpi4` — and every
# other Pi4 that tracks it, like it-03400 — untouched at its stock defaults,
# and it gives pikvm01 a self-update ref that carries these box-specific ones.
{ lib, ... }:
{
  # This kiosk drives an iPad → relative single-mouse HID. Seed the fresh-install
  # mode to ipad so a newly-flashed card comes up in relative mode instead of the
  # stock desktop/absolute default (which was the post-swap "HID came up absolute"
  # bug on the pikvm-nixos migration). NOTE: per modules/hidmode.nix this seeds the
  # mutable /var state ONCE on first boot and is NOT re-applied on redeploy — the
  # runtime hidMode switch + its persisted yaml remain the single source of truth
  # (#53) once the box is provisioned. So this fixes the fresh-flash default only;
  # it does not fight a deliberate runtime switch on an already-running box.
  services.pikvm.kvmd.hidMode.default = "ipad";

  # Self-update from THIS host's config, not `#rpi4`. hosts/rpi4.nix sets
  # deployment.updateRef to `#rpi4` with mkDefault; a plain assignment here
  # wins, so pikvm01 tracks the ipad-default configuration on its weekly
  # auto-upgrade (deployment.nix feeds this through to autoUpgrade.flake).
  services.pikvm.deployment.updateRef = "#pikvm01";

  # Deployment-fact metadata (Phase 3 architecture split — see
  # modules/deployment.nix). Not yet consumed by hidmode.nix/hid-latch-
  # monitor.nix (Phase 4, in flight); the two explicit overrides above/below
  # remain what's actually functional until that lands.
  services.pikvm.deployment.target = {
    kind = "ipad";
    alwaysAttached = true;
  };

  # Narrow the HID-latch monitor's healthy-state set to JUST "configured" (the
  # default also accepts "not attached", since most boxes get legitimately
  # unplugged). pikvm01's iPad is permanently cabled — it should never read
  # "not attached" while legitimately healthy — so narrowing lets the monitor
  # also catch the VBUS-latch second fault mode (docs/decisions/0003-hid-latch-
  # monitor.md names this box by name as needing it), at the correct tradeoff
  # for this box: a genuine iPad unplug now also fires the alarm.
  services.pikvm.hidLatchMonitor.healthyStates = [ "configured" ];
}
