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
{ self, pkgs }:
let
  # A tiny stream-WS client used by the OCR crash-path guard: it opens the SAME
  # ws?stream=1 the KVM dashboard opens (over kvmd's unix socket, authed the
  # reliable header way) and prints the first event kvmd pushes. Connecting
  # makes kvmd run its initial-state snapshot, which drives the OCR deadly-task
  # poller (get_state -> get_available_langs) — the exact daemon-killer on HW.
  ocrWsProbe = pkgs.writeText "ocr-ws-probe.py" ''
    import asyncio, sys, aiohttp
    async def main():
        conn = aiohttp.UnixConnector(path="/run/kvmd/kvmd.sock")
        hdr = {"X-KVMD-User": "admin", "X-KVMD-Passwd": "admin"}
        async with aiohttp.ClientSession(connector=conn, headers=hdr) as s:
            async with s.ws_connect("http://localhost/ws?stream=1") as ws:
                msg = await asyncio.wait_for(ws.receive(), timeout=10)
                sys.stdout.write(str(msg.data)[:300])
    asyncio.run(main())
  '';
  pyWs = pkgs.python3.withPackages (p: [ p.aiohttp ]);
in
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

      # atx.type=gpio opens /dev/gpiochip0 (absent in the VM → FileNotFoundError),
      # so disable it. msd.type=otg is KEPT ENABLED (the appliance default): its
      # gadget-assembly path writes the mass-storage lun attr inquiry_string_cdrom,
      # which is a PiKVM-kernel patch the vendor kernel (6.18.34) AND the generic
      # VM kernel both lack — so this is exactly where the real OTG-dead bug lives,
      # and enabling msd here reproduces it (see the OTG-bind assertions below).
      #
      # ⚠️ LOAD-BEARING: do NOT set msd.type = "disabled" here. The OTG-bind guard
      # below only exercises the inquiry_string_cdrom path because add_msd() runs,
      # which requires msd enabled. Disabling msd silently vacuums that guard
      # (no mass_storage function ⇒ the failing write never happens).
      services.pikvm.kvmd.settings.kvmd = {
        atx.type = "disabled";
      };

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

    # --- kvmd must actually SERVE (not just exec) ------------------------
    # wait_for_unit on a Type=simple unit returns the instant kvmd execs —
    # BEFORE its Python on_startup runs (which can crash). So assert kvmd
    # really serves its API on the socket, and that the OTG HID symlinks the
    # udev rules create actually appear (the missing-hid-udev regression).
    # Hit kvmd's socket DIRECTLY (no nginx here), so use kvmd's root route
    # /auth/check — there is no /api prefix on kvmd's own routes (that prefix
    # is only the nginx front-door convention).
    # (Crash-loop survival is asserted below via MainPID after the OCR poller
    # is driven — NOT via NRestarts, which systemd resets on its own.)
    machine.wait_until_succeeds(
        "${pkgs.curl}/bin/curl -s --unix-socket /run/kvmd/kvmd.sock"
        " http://localhost/auth/check -o /dev/null -w '%{http_code}' | grep -qE '401|403'",
        timeout=90,
    )
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_until_succeeds("test -e /dev/kvmd-hid-keyboard", timeout=15)

    # --- kvmd-otg: the port bugs must be gone ----------------------------
    # kvmd-otg now parses --main-config correctly (not the Arch
    # /usr/lib/kvmd/main.yaml default) and loads libc, and assembles the USB
    # gadget in configfs.
    otg_log = machine.execute("journalctl -u kvmd-otg.service --no-pager")[1]
    assert "invalid wrapper value" not in otg_log, \
        "regression: kvmd-otg fell back to the /usr/lib/kvmd/main.yaml default"
    assert "Where is libc" not in otg_log, \
        "regression: kvmd.libc could not load libc"

    # --- the OTG gadget must actually BIND (with MSD enabled) ------------
    # With msd.type=otg (the appliance default, enabled above), add_msd() writes
    # the mass-storage lun attr inquiry_string_cdrom — a PiKVM-kernel patch the
    # vendor kernel 6.18.34 AND this generic VM kernel both lack. configfs
    # returns EACCES (not ENOENT) for a missing attr, so the unguarded write
    # ABORTS assembly BEFORE the UDC bind → the gadget never binds → HID/MSD are
    # dead while systemd still reports the unit active (a false green — the exact
    # trap it-03400 caught on HW). Making that write optional=True (pkgs/kvmd)
    # lets assembly skip the absent attr and reach the UDC bind. So assert the
    # gadget is genuinely BOUND (UDC non-empty) and the MSD function is present
    # AND linked into the config — not merely that the unit is "active". Without
    # the fix this section fails (no bind / PermissionError), so it can fail.
    gadget = "/sys/kernel/config/usb_gadget/kvmd"
    assert "PermissionError" not in otg_log, \
        f"kvmd-otg assembly hit PermissionError (inquiry_string_cdrom?):\n{otg_log}"
    machine.wait_until_succeeds(f"test -s {gadget}/UDC", timeout=15)
    print("bound UDC: " + machine.succeed(f"cat {gadget}/UDC"))
    machine.succeed(f"test -d {gadget}/functions/mass_storage.usb0")
    machine.succeed(f"test -e {gadget}/configs/c.1/mass_storage.usb0")

    # --- lazily-dlopened native libs must resolve ------------------------
    # Regression guard for the find_library(...)->None fixes. On a stock
    # appliance find_library returns None (no ld.so.cache), so keyboard-paste
    # (libxkbcommon) and OCR (libtesseract) die at runtime even though boot is
    # fine. Assert kvmd's installed loaders now reference the store sonames
    # instead of find_library, AND that those exact libs actually dlopen.
    kvmd = "${pkgs.pikvm.kvmd}"
    machine.succeed(
        f"grep -q 'libxkbcommon.so.0' {kvmd}/lib/python*/site-packages/kvmd/keyboard/printer.py"
    )
    machine.succeed(
        f"grep -q 'libtesseract.so.5' {kvmd}/lib/python*/site-packages/kvmd/apps/kvmd/ocr.py"
    )
    machine.succeed(
        "${pkgs.python3}/bin/python3 -c '"
        'import ctypes; '
        'ctypes.CDLL("${pkgs.lib.getLib pkgs.libxkbcommon}/lib/libxkbcommon.so.0"); '
        'ctypes.CDLL("${pkgs.lib.getLib pkgs.pikvm.kvmd.tesseract}/lib/libtesseract.so.5")'
        "'"
    )

    # --- OCR data dir must resolve (tessdata Arch-ism regression) ---------
    # kvmd's ocr.tessdata defaulted to the Arch /usr/share/tessdata, absent on
    # NixOS. Enumerating languages (get_available_langs -> os.listdir) then
    # raised FileNotFoundError inside the OCR poller — a kvmd "deadly task" —
    # so kvmd crash-looped on every KVM-page open (deterministic HW repro).
    # The dlopen check above proves the *library* loads; it says nothing about
    # the *data dir*, which is what broke, and nothing in the suite ever drove
    # the OCR poll path (poll_state -> get_state -> get_available_langs) — which
    # is exactly why all checks were green while real HW crash-looped.
    #
    # Baseline the SOUND death signal BEFORE driving OCR: kvmd's MainPID, which
    # changes iff the main process actually died+respawned. (NRestarts is
    # unsound — systemd zeroes it on its own across a start-limit window / a
    # switch, so it can read 0 right after the very crash it should catch;
    # measured on real HW. MainPID is the direct signal.)
    pid_before = machine.succeed(
        "systemctl show kvmd.service -p MainPID --value"
    ).strip()

    # (1) Functional guard: GET /streamer/ocr (authed on kvmd's own socket, no
    # /api prefix) calls get_state -> get_available_langs directly. 200 + eng
    # present proves BOTH that the path is rewritten AND that the tessdata
    # actually carries a language — pointing it at an empty dir would 200 with
    # [] here, so this assertion can genuinely fail.
    import json
    ocr = machine.succeed(
        "${pkgs.curl}/bin/curl -s --unix-socket /run/kvmd/kvmd.sock"
        " -H 'X-KVMD-User: admin' -H 'X-KVMD-Passwd: admin'"
        " http://localhost/streamer/ocr"
    )
    print(ocr)
    ocr_state = json.loads(ocr)["result"]["ocr"]
    assert ocr_state["enabled"], f"OCR must be enabled (libtesseract linked): {ocr}"
    assert "eng" in ocr_state["langs"]["available"], \
        f"OCR tessdata must list English (dir rewritten + populated): {ocr}"

    # (2) Crash-path guard: open the SAME stream WS the KVM dashboard opens
    # (/ws?stream=1) so kvmd's initial-state snapshot runs the OCR deadly-task
    # poller — the actual daemon-killer on HW. Assert it streamed real state
    # (non-empty, so a failed upgrade fails loudly rather than passing vacuously).
    ws = machine.succeed("${pyWs}/bin/python3 ${ocrWsProbe}")
    print(ws[:500])
    assert ws.strip(), "stream WS produced no events — upgrade/subscribe failed"

    # (3) The daemon must have survived both the HTTP and the poller path:
    # MainPID unchanged (and non-zero), and no crash line in the journal. On the
    # broken build the poller kills kvmd here → MainPID changes (measured on HW:
    # 21433 -> 21959 on a single stream WS), so this assertion genuinely fails.
    pid_after = machine.succeed(
        "systemctl show kvmd.service -p MainPID --value"
    ).strip()
    assert pid_after not in ("", "0") and pid_after == pid_before, \
        f"kvmd MainPID changed {pid_before} -> {pid_after}: the daemon died driving OCR"
    kvmd_log = machine.execute("journalctl -u kvmd.service --no-pager")[1]
    assert "killing myself" not in kvmd_log, \
        f"kvmd hit a deadly-task crash (OCR poller?):\n{kvmd_log}"
    assert "tessdata" not in kvmd_log, f"tessdata error in kvmd journal:\n{kvmd_log}"
  '';
}
