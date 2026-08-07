# Standing gate: the OTG gadget the kernel ASSEMBLES must match the mode that
# was selected — and must still match after a reboot.
#
# Two gates live here (#51, gates 1 and 2 of 4):
#
#   1. ASSEMBLY   — read configfs/sysfs ground truth after the gadget comes up
#                   and assert the function set, each function's protocol /
#                   subclass / report_length / descriptor sha256, and the
#                   surviving /dev/kvmd-hid-* nodes.
#   2. PERSISTENCE— reboot, then assert the same thing again. A mode that only
#                   holds until the next boot is not a mode, it is a session.
#
# WHY GROUND TRUTH AND NOT THE CONFIG FLAG: a flag records an intention. The
# assembled gadget is the only thing a host can act on, and the two come apart
# — that is the #49 failure (deployed != live) in the OTG path. So this test
# never reads back the setting it just wrote; it reads the kernel.
#
# WHAT THIS TEST DOES NOT CLAIM: nothing behavioural. It proves the gadget is
# assembled as specified, never that a keystroke or click lands on a host —
# that needs a real host on the other end of the cable and belongs to the
# node that has one. A green here is "assembles as the mode claims", full stop.
#
# The negative control at the end is the point of the whole file: a gate that
# has only ever been observed passing is not known to be a gate. We break the
# gadget for real and require the RED.
{ self, pkgs }:
let
  snapshot = pkgs.runCommandLocal "otg-gadget-snapshot" { } ''
    mkdir -p "$out/bin"
    cp ${./lib/otg-gadget-snapshot.sh} "$out/bin/otg-gadget-snapshot"
    chmod +x "$out/bin/otg-gadget-snapshot"
  '';
  assertMode = pkgs.runCommandLocal "otg-assert-mode" { } ''
    mkdir -p "$out/bin" "$out/share"
    cp ${./lib/otg_assert_mode.py} "$out/bin/otg-assert-mode"
    chmod +x "$out/bin/otg-assert-mode"
    cp ${./lib/otg-mode-specs.json} "$out/share/otg-mode-specs.json"
  '';
in
{
  name = "pikvm-otg-mode-assembly";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/kvmd.nix
        ../modules/otg.nix
      ];

      services.pikvm.kvmd.enable = true;
      services.pikvm.kvmd.platform = "auto";
      services.pikvm.otg.enable = true;

      # Same VM accommodation as kvmd-services.nix / hid-recovery.nix: the
      # generic kernel has neither the vendor MSD configfs attr nor
      # /dev/gpiochip0, and kvmd would crash-loop before the gadget binds.
      # Neither touches the HID assembly this test is about.
      services.pikvm.kvmd.settings.kvmd = {
        msd.type = "disabled";
        atx.type = "disabled";
      };
      boot.kernelModules = [ "dummy_hcd" ];

      environment.systemPackages = [
        snapshot
        assertMode
        pkgs.python3
      ];

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    specs = "${assertMode}/share/otg-mode-specs.json"

    def assert_mode(mode, hw, expect, why):
        """Snapshot the live gadget and assert it against `mode`.

        expect: 0 PASS / 1 FAIL / 2 NOT-VERIFIED. Asserting the exact code
        (not merely "nonzero") is deliberate — it keeps a NOT-VERIFIED from
        ever being mistaken for a pass, and keeps a genuine FAIL from being
        satisfied by an unrelated crash.
        """
        machine.succeed("otg-gadget-snapshot > /tmp/snap.json")
        rc, out = machine.execute(
            f"otg-assert-mode --snapshot /tmp/snap.json --specs {specs} "
            f"--mode {mode} --horizontal-wheel {hw} 2>&1"
        )
        print(f"--- {why}\n{out}")
        assert rc == expect, (
            f"{why}: expected exit {expect}, got {rc}\n{out}"
        )
        return out

    start_all()
    machine.wait_for_unit("kvmd-otg.service")

    udc = machine.succeed("ls /sys/class/udc | head -n1").strip()
    assert udc, "no UDC registered — nothing to assemble a gadget onto"
    machine.wait_until_succeeds(
        "test -e /sys/kernel/config/usb_gadget/kvmd/UDC", timeout=30
    )
    machine.wait_until_succeeds("test -e /dev/kvmd-hid-keyboard", timeout=30)

    # --- GATE 1: assembly ------------------------------------------------
    # The descriptor hashes in the spec were measured on the real aarch64
    # appliance. They hold here too, and that is a claim worth testing rather
    # than assuming: a report descriptor is a pure function of the kvmd code
    # and the mouse settings, so it must NOT vary with host architecture or
    # with the UDC underneath. If this ever diverges from the appliance, one
    # of those two assumptions has broken and we want to hear about it.
    assert_mode("stock-default", "true", 0, "GATE 1: gadget assembled as the mode claims")

    # --- the three-outcome contract --------------------------------------
    # A mode nobody has recorded expectations for must come back NOT-VERIFIED,
    # never PASS. This is the anti-"green because nothing was compared" check;
    # if it ever returns 0 the engine has started laundering unknowns.
    #
    # The placeholder case uses a permanent synthetic fixture rather than a
    # real mode on purpose. It used to point at "ipad", which broke the moment
    # iPad got real expectations — and the tempting fix (drop the assertion)
    # would have quietly retired the guarantee exactly when the table stopped
    # having any placeholders left to catch.
    assert_mode("_selftest-placeholder", "true", 2,
                "placeholder mode must be NOT-VERIFIED, not a pass")
    assert_mode("no-such-mode", "true", 2, "unknown mode must be NOT-VERIFIED, not a pass")

    # --- discrimination: the gate must tell the modes APART ---------------
    # A gate that passes the mode it was handed proves little if it would pass
    # any mode. The gadget here is desktop-shaped, so asserting it against the
    # iPad expectations must go RED — and must go red for the right reasons:
    # an alt mouse that should not exist, and a primary mouse carrying the
    # absolute interface pair instead of the relative one.
    for wheel in ("false", "true"):
        out = assert_mode(
            "ipad", wheel, 1,
            f"desktop-shaped gadget must FAIL the ipad/hw={wheel} expectations",
        )
        assert "hid.usb2" in out, "the RED must name the alt mouse that should be absent"
        assert "hid.usb1.protocol" in out, (
            "the RED must name the primary mouse's protocol mismatch — the "
            "absolute/relative distinction lives in protocol+subclass, which "
            "are interface fields and are INVISIBLE in the descriptor bytes"
        )

    # --- GATE 2: persistence across reboot --------------------------------
    # georg's requirement: a runtime-selected mode MUST survive. A gadget is
    # assembled fresh on every boot, so "it was right once" says nothing about
    # whether it is right tomorrow.
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_until_succeeds("test -e /dev/kvmd-hid-keyboard", timeout=60)
    assert_mode("stock-default", "true", 0, "GATE 2: mode survives a reboot")

    # --- NEGATIVE CONTROL: prove the gate can actually fail ---------------
    # Everything above is green. Green proves nothing unless the same check
    # goes red on a bad gadget, so we produce a real one: unlink the alt mouse
    # from the configuration, exactly the half-applied state a silently
    # non-applying mode would leave behind. The function directory stays put
    # and stays readable — which is why the snapshot must read the config's
    # links rather than the functions pool. Reading the pool reports the
    # removed mouse as still present, and this control is what caught that.
    gadget = "/sys/kernel/config/usb_gadget/kvmd"
    cfg = machine.succeed(f"ls -d {gadget}/configs/*/ | head -n1").strip()
    machine.succeed(f'echo "" > {gadget}/UDC')
    machine.succeed(f"rm -f {cfg}/hid.usb2")
    machine.succeed(f'echo "{udc}" > {gadget}/UDC')

    out = assert_mode(
        "stock-default", "true", 1,
        "NEGATIVE CONTROL: unlinked alt mouse must go RED",
    )
    # ...and the diagnosis must name the actual fault, not just "something
    # differs". A red that misdescribes the failure sends the next person to
    # the wrong subsystem.
    assert "hid.usb2" in out, "the RED must name the function that went missing"
    assert "NOT LINKED" in out, (
        "the RED must distinguish 'built but not assembled' from 'absent entirely' — "
        "same symptom to a host, different bug to chase"
    )

    # --- restore, and prove the restore worked ----------------------------
    # Via the real service path, not by hand-relinking: that also demonstrates
    # kvmd-otg rebuilds the gadget correctly, which is the recovery the
    # appliance depends on.
    machine.succeed("systemctl restart kvmd-otg.service")
    machine.wait_until_succeeds("test -e /dev/kvmd-hid-mouse-alt", timeout=60)
    assert_mode("stock-default", "true", 0, "restored: back to green after the injected fault")
  '';
}
