# VM test for the HID-recovery privileged host ops (modules/hid-recovery.nix).
#
# Boots a real kvmd + OTG gadget on dummy_hcd (same VM accommodation as
# kvmd-services: msd/atx disabled, which the generic VM kernel can't provide),
# so there is an actual bound USB gadget + UDC to recover. Then it proves:
#   * pikvm-hid-recover@soft_connect and @udc-rebind actually run and leave the
#     UDC re-enumerated ("configured") — the real recovery, not a no-op;
#   * the polkit least-privilege grant — the endpoint's triggerUser may start
#     ONLY the pikvm-hid-recover@ units, nothing else.
# `reboot` is not exercised (it would reboot the test VM); it's real-rig only.
#
# The endpoint half (authenticated loopback → systemctl start) is a separate
# module; here we stub only its user so the polkit subject exists.
{ self, pkgs }:
{
  name = "pikvm-hid-recovery";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/kvmd.nix
        ../modules/otg.nix
        ../modules/hid-recovery.nix
      ];

      services.pikvm.kvmd.enable = true;
      services.pikvm.kvmd.platform = "auto";
      services.pikvm.otg.enable = true;
      # Same VM-hardware accommodation as kvmd-services.nix: the generic kernel
      # can't do the vendor MSD cdrom attr or /dev/gpiochip0, and kvmd would
      # crash-loop; disable those so kvmd comes up and the HID gadget binds.
      services.pikvm.kvmd.settings.kvmd = {
        msd.type = "disabled";
        atx.type = "disabled";
      };
      boot.kernelModules = [ "dummy_hcd" ];

      services.pikvm.hidRecovery.enable = true;

      # Stand-in for the recovery endpoint's user (the endpoint module creates it
      # for real). Its only purpose here is to be the polkit subject.
      users.groups.pikvm-hid-recovery = { };
      users.users.pikvm-hid-recovery = {
        isSystemUser = true;
        group = "pikvm-hid-recovery";
      };

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    start_all()

    # kvmd-otg binds the composite gadget on dummy_hcd's virtual UDC; the
    # dummy_hcd loopback host then enumerates it to "configured".
    machine.wait_for_unit("kvmd-otg.service")
    udc = machine.succeed("ls /sys/class/udc | head -n1").strip()
    assert udc, "no UDC registered under /sys/class/udc"
    print(f"UDC = {udc}")
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- soft_connect: the primary ~6s recovery -------------------------
    machine.succeed("systemctl start pikvm-hid-recover@soft_connect.service")
    machine.succeed("journalctl -u pikvm-hid-recover@soft_connect.service | grep -q 'soft_connect on'")
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- udc-rebind: idempotent, must NOT hit the kvmd-otg FileExistsError ---
    machine.succeed("systemctl start pikvm-hid-recover@udc-rebind.service")
    machine.succeed("journalctl -u pikvm-hid-recover@udc-rebind.service | grep -q 'udc-rebind'")
    # run it a SECOND time to prove idempotency (rebind on an already-bound UDC)
    machine.succeed("systemctl start pikvm-hid-recover@udc-rebind.service")
    machine.wait_until_succeeds(
        f"test \"$(cat /sys/class/udc/{udc}/state)\" = configured", timeout=30
    )

    # --- polkit least-privilege -----------------------------------------
    # The endpoint's user may start ONLY the recovery units...
    machine.succeed(
        "runuser -u pikvm-hid-recovery -- systemctl start pikvm-hid-recover@soft_connect.service"
    )
    # ...and nothing else (an arbitrary unit is denied by polkit, non-interactive).
    machine.fail(
        "runuser -u pikvm-hid-recovery -- systemctl start systemd-tmpfiles-clean.service"
    )
  '';
}
