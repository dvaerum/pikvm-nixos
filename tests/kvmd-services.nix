# First NixOS VM test for the PiKVM stack: boot the services module and prove
# the systemd wiring + declarative /etc/kvmd materialisation + platform=auto
# detector actually work at runtime (not just eval/build).
#
# Runs NATIVELY per host architecture — wired as checks.<system> in flake.nix,
# so an x86_64 host boots an x86_64 guest and an aarch64 host an aarch64 guest,
# with no cross-arch emulated VM. It therefore exercises the SERVICE/CONFIG/
# detector logic, NOT the Pi vendor-kernel / TC358743 CSI capture path (that
# needs real hardware).
#
# We import the individual feature modules rather than the aggregate
# `nixosModules.pikvm` (which sets `nixpkgs.overlays`) — runNixOSTest pins
# nixpkgs read-only, so a node may not set overlays. The pikvm.* packages the
# modules need are already present because flake.nix calls runNixOSTest on a
# pkgs set that carries the overlay, and nodes inherit it as their hostPkgs.
{ self }:
{
  name = "pikvm-kvmd-services";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/kvmd.nix
        ../modules/otg.nix
        ../modules/system/auto-upgrade.nix
      ];

      services.pikvm.kvmd.enable = true;
      services.pikvm.kvmd.platform = "auto";
      services.pikvm.otg.enable = true;
      # No self-updates inside the test VM.
      services.pikvm.autoUpgrade.enable = false;

      # dummy_hcd provides a virtual USB Device Controller so the OTG gadget
      # can actually bind in the VM (there's no real dwc2 UDC here). Test-only.
      boot.kernelModules = [ "dummy_hcd" ];

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    start_all()

    # --- platform=auto detector (oneshot) --------------------------------
    machine.wait_for_unit("kvmd-platform-detect.service")

    # It must materialise the runtime selection...
    machine.succeed("test -L /run/kvmd/main.yaml")
    machine.succeed("test -f /run/kvmd/platform")
    # ...pointing at a profile that actually exists in the store.
    machine.succeed("test -e $(readlink -f /run/kvmd/main.yaml)")
    print(machine.succeed("readlink /run/kvmd/main.yaml"))
    print(machine.succeed("cat /run/kvmd/platform"))

    # --- declarative /etc/kvmd override.d --------------------------------
    machine.succeed("test -f /etc/kvmd/override.d/00-nixos-paths.yaml")
    machine.succeed("test -f /etc/kvmd/override.d/10-settings.yaml")
    # The nixos-paths override must rewrite the baked /usr defaults to store paths.
    machine.succeed("grep -q /nix/store /etc/kvmd/override.d/00-nixos-paths.yaml")

    # --- the daemons actually run ----------------------------------------
    # (Regression guard: kvmd/kvmd-media must find the `ustreamer` python
    # module and load libc. They order after network-online, so wait for them.)
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("kvmd-media.service")

    # --- kvmd-otg: the port bugs must be gone ----------------------------
    # kvmd-otg now parses --main-config correctly (not the Arch
    # /usr/lib/kvmd/main.yaml default) and loads libc, and gets as far as
    # assembling the USB gadget in configfs. Full gadget bring-up needs the Pi
    # vendor kernel's OTG/MSD configfs support (e.g. inquiry_string_cdrom),
    # which a generic VM kernel lacks — so we assert the two port-bug
    # signatures are gone rather than requiring the unit to reach active.
    otg_log = machine.execute("journalctl -u kvmd-otg.service --no-pager")[1]
    assert "invalid wrapper value" not in otg_log, \
        "regression: kvmd-otg fell back to the /usr/lib/kvmd/main.yaml default"
    assert "Where is libc" not in otg_log, \
        "regression: kvmd.libc could not load libc"
  '';
}
