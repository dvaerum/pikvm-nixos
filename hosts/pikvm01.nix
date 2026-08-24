# pikvm01 — the production WB-kiosk Pi4B whose KVM target is an iPad.
#
# Identical hardware/stack to the generic `rpi4` target (hosts/default.nix builds
# this config as `rpi4` modules + this file), so it inherits the vendor kernel,
# disko layout, direct-kernel boot, and the whole PiKVM stack. It differs from
# `rpi4` in exactly two per-box ways, both because this specific box drives an
# iPad (relative/single-mouse HID) rather than the desktop/absolute target the
# shared `rpi4` config stays faithful to (e.g. it-03400's cabled monitor):
#
#   1. the FRESH-INSTALL HID mode is iPad, not the stock desktop default; and
#   2. it self-updates from its OWN config attribute, not `#rpi4`.
#
# Keeping this as a distinct host (rather than flipping the shared `rpi4`
# default) is the declarative, drift-free answer: it leaves `rpi4` — and every
# other Pi4 that tracks it, like it-03400 — untouched at the stock desktop
# default, and it gives pikvm01 a self-update ref that carries THIS iPad default.
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

  # Self-update from THIS host's config, not `#rpi4`. hosts/rpi4.nix sets the ref
  # to `#rpi4` with mkDefault; a plain assignment here wins, so pikvm01 tracks the
  # ipad-default configuration on its weekly auto-upgrade. (The module's hostName-
  # based default is bypassed by this explicit ref, same as rpi4 does.)
  services.pikvm.autoUpgrade.flake = "github:dvaerum/pikvm-nixos#pikvm01";
}
