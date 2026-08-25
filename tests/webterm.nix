# VM test for the Phase 2.5 web Terminal (kvmd-webterm) through the real nginx 443
# front-door. Proves the mechanics (a literal GUI button-click + interactive shell
# is the on-device final confirm, like the MJPEG frame): kvmd registers the webterm
# extra (what renders the menu button), the /extras/webterm/ttyd proxy INHERITS the
# dashboard auth (refused without creds, 200 through to ttyd with admin creds — so
# the composed extrasDir glob-include wired nginx to the /run/kvmd/ttyd.sock socket
# and nginx's kvmd-webterm group membership reaches it), and the composed web root
# serves the menu icon.
#
# MCP is left OFF — webterm is independent of it, and skipping onnxruntime keeps the
# VM light. @nixos-developer-system runs the booted VM.
{ self, pkgs }:
{
  name = "pikvm-webterm";

  nodes.machine = {
    imports = [
      ../modules/kvmd.nix
      ../modules/otg.nix # kvmd.nix references services.pikvm.otg.enable
      ../modules/mcp-integration.nix
      ../modules/nginx.nix
      ../modules/webterm.nix # declares services.pikvm.web.terminal + the kvmd-webterm unit/user
      self.nixosModules.mcp-server # declares services.pikvm-mcp (left off here)
    ];

    services.pikvm.kvmd.enable = true;
    services.pikvm.kvmd.platform = "auto";
    # dummy_hcd gives a virtual UDC so the OTG gadget binds and kvmd (platform=auto)
    # comes up — same VM accommodation as kvmd-services/mcp-proxy.
    services.pikvm.otg.enable = true;
    boot.kernelModules = [ "dummy_hcd" ];
    services.pikvm.kvmd.settings.kvmd = {
      msd.type = "disabled";
      atx.type = "disabled";
    };

    services.pikvm.web.enable = true; # the 443 dashboard front-door
    services.pikvm.web.terminal.enable = true; # + the web Terminal (Phase 2.5)
    services.pikvm-mcp.enable = false; # webterm needs no MCP; skip onnxruntime

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("kvmd-webterm.service") # ttyd on /run/kvmd/ttyd.sock

    # nginx reaches kvmd's socket: unauthenticated /api/auth/check is 401 but
    # REACHABLE (not 502), proving the front-door works.
    machine.wait_until_succeeds(
        "test $(curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/auth/check) = 401"
    )
    # Seed a real PiKVM user (same idiom as mcp-proxy.nix).
    machine.succeed("printf 'secretpw\\n' | ${pkgs.pikvm.kvmd}/bin/kvmd-htpasswd add alice -i")
    A = "-u alice:secretpw"

    # (1) kvmd registers the webterm extra → the dashboard renders the button.
    # kvmd reads kvmd.info.extras (our composed extrasDir) and reports it on
    # /api/info. Assert the EXACT advertised set is {webterm}: webterm present
    # AND the stock ipmi/vnc extras filtered out (their kvmd-ipmi/kvmd-vnc
    # daemons aren't packaged → advertising them = a DBusError on every
    # /api/info). This is the composed extrasDir = kvmd-extras (∅) ∪ webterm.
    import json
    info = machine.succeed(f"curl -sk {A} 'https://localhost/api/info?fields=extras'")
    extras = json.loads(info)["result"]["extras"]
    assert set(extras.keys()) == {"webterm"}, \
        f"advertised extras must be EXACTLY {{webterm}} (ipmi/vnc filtered); got {sorted(extras.keys())}"

    # (1b) nginx -t must still pass with the new extrasDir join (georgs ASK 2) —
    # belt-and-suspenders that the extras/*/nginx.ctx-*.conf include glob still
    # resolves the webterm ctx files through the filtered composition. (Steps
    # 2/3 below already prove the glob ACTIVATES webterm — 200 through ttyd —
    # but validate the config explicitly too.)
    import re
    execstart = machine.succeed("systemctl cat nginx.service | grep -m1 -oE 'ExecStart=.*'")
    m = re.search(r"ExecStart=(\S+).* -c (\S+)", execstart)
    assert m, f"couldn't parse nginx ExecStart: {execstart!r}"
    machine.succeed(f"{m.group(1)} -t -c {m.group(2)}")

    # (2) The ttyd proxy inherits the server-level auth_request — WITHOUT creds it is
    # refused / redirected to login (NOT open to the internet).
    code = machine.succeed(
        "curl -sk -o /dev/null -w '%{http_code}' https://localhost/extras/webterm/ttyd/"
    ).strip()
    assert code in ("401", "302", "403"), f"webterm must NOT be open without creds; got {code}"

    # (3) WITH admin creds → 200 through to ttyd (the /run/kvmd/ttyd.sock upstream is
    # up and nginx — in the kvmd-webterm group — reaches it).
    code = machine.succeed(
        f"curl -sk {A} -o /dev/null -w '%{{http_code}}' https://localhost/extras/webterm/ttyd/"
    ).strip()
    assert code == "200", f"authed webterm must reach ttyd (200); got {code}"

    # (4) The menu icon is served from the composed web root.
    code = machine.succeed(
        f"curl -sk {A} -o /dev/null -w '%{{http_code}}' https://localhost/extras/webterm/terminal.svg"
    ).strip()
    assert code == "200", f"webterm icon must be served (200); got {code}"
  '';
}
