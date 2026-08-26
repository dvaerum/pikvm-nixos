# VM test for the runtime iPad/desktop HID-mode switch (#51, modules/hidmode.nix
# + hidmode-endpoint.nix). Proves the mechanics I own: the /var seed + the
# read-last 90-hidmode.yaml symlink, the loopback endpoint's GET/POST auth, and
# — the load-bearing bit — that a switch actually RE-ASSEMBLES the gadget to the
# other topology. The both-directions gadget check: the mouse-alt HID node is
# present in desktop (dual mouse) and GONE in ipad (single relative), then
# reappears on switch-back. That complements it-03400's descriptor-sha assembly
# gate (otg-mode-specs.json) rather than duplicating it.
#
# dummy_hcd gives a virtual UDC so kvmd-otg binds and the hidgN devices appear,
# same accommodation as kvmd-services/webterm. MCP is left OFF (the endpoint is
# enabled explicitly, so we exercise it without pulling onnxruntime into the VM).
# @nixos-developer-system runs the booted VM.
{ self, pkgs }:
{
  name = "pikvm-hidmode";

  nodes.machine = {
    imports = [
      ../modules/kvmd.nix
      ../modules/otg.nix
      ../modules/runtime-paths.nix
      ../modules/deployment.nix # hidMode.default's own default reads this (Phase 4)
      ../modules/system/auto-upgrade.nix # deployment.nix's config unconditionally targets this option
      ../modules/mcp-integration.nix
      ../modules/hidmode.nix
      ../modules/hidmode-endpoint.nix
      self.nixosModules.mcp-server # declares services.pikvm-mcp (left off here)
    ];

    services.pikvm.kvmd.enable = true;
    services.pikvm.kvmd.platform = "auto";
    services.pikvm.otg.enable = true;
    boot.kernelModules = [ "dummy_hcd" ];

    # The endpoint references services.pikvm-mcp; import the module so the option
    # exists, but leave the MCP OFF (skips onnxruntime, keeps the VM light — same
    # accommodation as webterm.nix). The endpoint's default keys off pikvm-mcp,
    # so enable it explicitly to exercise it standalone.
    services.pikvm-mcp.enable = false;
    services.pikvm.kvmd.hidMode.endpoint.enable = true;

    services.pikvm.kvmd.settings.kvmd = {
      msd.type = "disabled";
      atx.type = "disabled";
    };

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    import json

    start_all()
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("pikvm-hidmode-endpoint.service")

    # (1) SEED = desktop (faithful fresh-install default). The single source is
    # the boot-authoritative override; the CLI `get` classifies it. There is NO
    # parallel marker file (#53 collapsed to one source).
    assert machine.succeed("pikvm-hidmode get").strip() == "desktop"
    machine.succeed("test ! -e /var/lib/kvmd/hidmode")

    # (1b) #53 fast-follow: a box UPGRADED from the pre-#53 scheme carries the
    # retired marker as inert residue. The tmpfiles `r` rule clears it on
    # activation. Simulate: plant a marker, run the tmpfiles remove pass (the
    # activation path), confirm it's gone — and the yaml/mode are untouched (the
    # marker is inert, so removing it changes nothing).
    machine.succeed("install -m0644 -o kvmd -g kvmd /dev/null /var/lib/kvmd/hidmode")
    machine.succeed("systemd-tmpfiles --remove")
    machine.succeed("test ! -e /var/lib/kvmd/hidmode")
    assert machine.succeed("pikvm-hidmode get").strip() == "desktop"

    # The mode is wired in as the LAST-read override.d drop-in: a symlink at 90-
    # (sorts after 00/10) pointing into the mutable /var file.
    machine.succeed("test -L /etc/kvmd/override.d/90-hidmode.yaml")
    # readlink -f: the entry is a generation-managed env.etc symlink (via
    # /etc/static), so resolve the whole chain to the mutable /var target.
    tgt = machine.succeed("readlink -f /etc/kvmd/override.d/90-hidmode.yaml").strip()
    assert tgt == "/var/lib/kvmd/hidmode.yaml", tgt

    # desktop override content: absolute primary mouse + mouse_alt present.
    d = json.loads(machine.succeed("cat /var/lib/kvmd/hidmode.yaml"))
    assert d["kvmd"]["hid"]["mouse"]["absolute"] is True, d
    assert d["kvmd"]["hid"]["mouse_alt"]["device"] == "/dev/kvmd-hid-mouse-alt", d

    # The gadget actually assembled the DUAL topology → the mouse-alt HID node
    # exists. (udev maps hidg2 → kvmd-hid-mouse-alt; the hidgN nodes appear only
    # when the function is assembled AND the gadget is bound to a UDC — dummy_hcd
    # provides one here, so this is an assembly+bind check, not assembly-only.)
    # This is the POSITIVE CONTROL for the "mouse-alt absent in ipad" assertion
    # in step (3): absence is meaningful only measured against this presence.
    machine.wait_for_file("/dev/kvmd-hid-mouse")
    machine.succeed("test -e /dev/kvmd-hid-mouse-alt")

    # (2) ENDPOINT auth. Without a token → 401; with the first-boot token →
    # desktop. The local CLI `get` must agree.
    tok = machine.succeed("cat /run/pikvm-hidmode/token").strip()
    code = machine.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8083/hidmode"
    ).strip()
    assert code == "401", code
    got = json.loads(machine.succeed(
        f"curl -s -H 'Authorization: Bearer {tok}' http://127.0.0.1:8083/hidmode"
    ))
    # GET reports the ASSEMBLED gadget (classified from configfs), not the config.
    # At the desktop seed the gadget is dual → observed=desktop, settled, and
    # requested (classified from the boot-authoritative yaml) agrees.
    assert got["mode"] == "desktop", got
    assert got["observed"] == "desktop", got
    assert got["requested"] == "desktop", got
    assert got["settled"] is True, got
    assert machine.succeed("pikvm-hidmode get").strip() == "desktop"  # CLI get classifies the same yaml

    # CORRECTNESS PROPERTY — torn-write / next-boot drift (#53). The
    # boot-authoritative override (/var/lib/kvmd/hidmode.yaml, what kvmd-otg
    # assembles from) is the SINGLE source of the next-boot mode. Simulate a torn
    # switch: point the yaml at ipad WITHOUT re-assembling the gadget. GET must
    # report `requested` = ipad (the yaml = what boots next) while `observed`/`mode`
    # stay desktop (the gadget's real NOW), so the divergence is visible and the
    # MCP still drives the true assembled mode. Pre-#53 `requested` read a parallel
    # /var marker written AFTER the yaml, so this exact case (yaml=new, marker=old)
    # reported requested==observed and the drift went undetected — #44's blind
    # spot, closed here by construction.
    machine.succeed(
        "printf '%s' "
        "'{\"kvmd\":{\"hid\":{\"mouse\":{\"absolute\":false,\"horizontal_wheel\":false},"
        "\"mouse_alt\":{\"device\":\"\"}}}}' > /var/lib/kvmd/hidmode.yaml"
    )
    drift = json.loads(machine.succeed(
        f"curl -s -H 'Authorization: Bearer {tok}' http://127.0.0.1:8083/hidmode"
    ))
    assert drift["requested"] == "ipad", drift       # yaml = next-boot (authoritative)
    assert drift["observed"] == "desktop", drift      # gadget = truth NOW
    assert drift["mode"] == "desktop", drift           # the MCP follows the gadget, not the config
    assert drift["settled"] is True, drift             # the gadget still cleanly classifies
    # restore the yaml to the desktop shape so the POST switch below starts clean
    machine.succeed(
        "printf '%s' "
        "'{\"kvmd\":{\"hid\":{\"mouse\":{\"absolute\":true},"
        "\"mouse_alt\":{\"device\":\"/dev/kvmd-hid-mouse-alt\"}}}}' > /var/lib/kvmd/hidmode.yaml"
    )

    # (3) SWITCH to ipad via POST. Non-blocking → poll the next-boot mode (the
    # boot-authoritative yaml, via the CLI) for the flip.
    r = json.loads(machine.succeed(
        "curl -s -X POST -H 'Authorization: Bearer " + tok + "' "
        "-d '{\"mode\":\"ipad\"}' http://127.0.0.1:8083/hidmode"
    ))
    assert r["ok"] and r["mode"] == "ipad", r
    machine.wait_until_succeeds("test \"$(pikvm-hidmode get)\" = ipad")
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_for_unit("kvmd.service")

    # override flipped to the single-relative shape …
    d2 = json.loads(machine.succeed("cat /var/lib/kvmd/hidmode.yaml"))
    assert d2["kvmd"]["hid"]["mouse"]["absolute"] is False, d2
    assert d2["kvmd"]["hid"]["mouse"]["horizontal_wheel"] is False, d2
    assert d2["kvmd"]["hid"]["mouse_alt"]["device"] == "", d2
    # … written ATOMICALLY (#53): no torn/partial override and no leftover temp
    # (`hidmode.yaml.XXXXXX`) residue from the temp+rename install.
    assert machine.succeed(
        "find /var/lib/kvmd -maxdepth 1 -name 'hidmode.yaml.*' | wc -l"
    ).strip() == "0"
    # … and the GADGET re-assembled to single-mouse: mouse-alt node is GONE,
    # primary mouse still present. Measured against the step-(1) positive control
    # in this SAME continuous run — do NOT split these three phases (present →
    # gone → reappears) into independent assertions: "absent" alone is
    # green-by-not-triggering (it also holds if kvmd-otg assembled nothing).
    machine.wait_until_fails("test -e /dev/kvmd-hid-mouse-alt")
    machine.succeed("test -e /dev/kvmd-hid-mouse")
    # GET now reports ipad — from the ASSEMBLED gadget (single relative mouse),
    # with requested (the boot-authoritative yaml) agreeing and settled true.
    got2 = json.loads(machine.succeed(
        f"curl -s -H 'Authorization: Bearer {tok}' http://127.0.0.1:8083/hidmode"
    ))
    assert got2["mode"] == "ipad", got2
    assert got2["observed"] == "ipad", got2
    assert got2["requested"] == "ipad", got2
    assert got2["settled"] is True, got2

    # (4) SWITCH BACK to desktop → the mouse-alt node reappears (dual restored),
    # proving the switch is reversible and not a one-way latch.
    machine.succeed(
        "curl -s -X POST -H 'Authorization: Bearer " + tok + "' "
        "-d '{\"mode\":\"desktop\"}' http://127.0.0.1:8083/hidmode"
    )
    machine.wait_until_succeeds("test \"$(pikvm-hidmode get)\" = desktop")
    machine.wait_for_unit("kvmd-otg.service")
    machine.wait_until_succeeds("test -e /dev/kvmd-hid-mouse-alt")
  '';
}
