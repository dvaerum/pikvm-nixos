# VM test for the #51 dashboard HID-mode control (modules/hidmode-web.nix) — the
# 443 front-door half. Proves the SECURITY shape, not just reachability:
#   - the /hidmode proxy + /hidmode-control page inherit the dashboard auth
#     (refused without a session — no anonymous switch path);
#   - a dashboard-authed request reaches the loopback endpoint ONLY because the
#     proxy injects the bearer SERVER-SIDE (non-vacuous: dashboard-auth alone
#     does not satisfy the endpoint's bearer check);
#   - the client CANNOT smuggle its own Authorization (the proxy overrides it);
#   - the token never appears in a served response;
#   - the switch drives end-to-end through the proxy (POST → marker flips);
#   - nginx -t is clean.
#
# MCP is OFF (endpoint.enable set explicitly) to skip onnxruntime and keep the VM
# light. dummy_hcd gives a virtual UDC so the OTG gadget binds and the switch's
# kvmd-otg restart works. @nixos-developer-system runs the booted VM.
{ self, pkgs }:
{
  name = "pikvm-hidmode-web";

  nodes.machine = {
    imports = [
      ../modules/kvmd.nix
      ../modules/otg.nix
      ../modules/nginx.nix # imports webterm.nix + hidmode-web.nix
      ../modules/hidmode.nix
      ../modules/hidmode-endpoint.nix
      self.nixosModules.mcp-server # declares services.pikvm-mcp (left off here)
    ];

    services.pikvm.kvmd.enable = true;
    services.pikvm.kvmd.platform = "auto";
    services.pikvm.otg.enable = true;
    boot.kernelModules = [ "dummy_hcd" ];
    services.pikvm.kvmd.settings.kvmd = {
      msd.type = "disabled";
      atx.type = "disabled";
    };

    services.pikvm.web.enable = true; # the 443 dashboard front-door
    # Turn the endpoint on WITHOUT the MCP (its default is MCP-tied); the web
    # control then defaults on (web.enable && endpoint.enable).
    services.pikvm.kvmd.hidMode.endpoint.enable = true;
    services.pikvm-mcp.enable = false;

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("pikvm-hidmode-token.service")
    machine.wait_for_unit("pikvm-hidmode-endpoint.service") # loopback :8083
    machine.wait_for_unit("pikvm-hidmode-proxy-auth.service") # server-side bearer include
    machine.wait_for_unit("nginx.service")

    # Front-door up: unauthenticated /api/auth/check is 401 but REACHABLE.
    machine.wait_until_succeeds(
        "test $(curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/auth/check) = 401"
    )
    machine.succeed("printf 'secretpw\\n' | ${pkgs.pikvm.kvmd}/bin/kvmd-htpasswd add alice -i")
    A = "-u alice:secretpw"

    # --- (1) no anonymous path to the switch ------------------------------
    # /hidmode (API) inherits the server-level auth_request → 401 without creds.
    code = machine.succeed("curl -sk -o /dev/null -w '%{http_code}' https://localhost/hidmode").strip()
    assert code == "401", f"unauthenticated /hidmode must be refused (401), got {code}"
    # /hidmode-control (page) redirects unauth to the login (loc-login 401→@login).
    pcode = machine.succeed("curl -sk -o /dev/null -w '%{http_code}' https://localhost/hidmode-control").strip()
    assert pcode in ("302", "303"), f"unauthenticated /hidmode-control must redirect to login, got {pcode}"

    # --- (2) authed request reaches the endpoint via the SERVER-SIDE bearer -
    # Non-vacuous: the endpoint itself requires the bearer; a dashboard-authed
    # request only succeeds because nginx injected it. Without the injection this
    # is 401.
    out = machine.succeed(f"curl -sk {A} https://localhost/hidmode")
    import json
    data = json.loads(out)
    assert data.get("ok") is True and data.get("mode") in ("desktop", "ipad"), \
        f"authed GET /hidmode must reach the endpoint (server-side bearer); got {out!r}"
    assert data["mode"] == "desktop", f"fresh install should seed desktop; got {data['mode']}"

    # --- (3) the client cannot smuggle / override the bearer --------------
    # A bogus client Authorization must be OVERRIDDEN by the server-side bearer,
    # so the request still succeeds (proves proxy_set_header wins, client ignored).
    code2 = machine.succeed(
        f"curl -sk {A} -H 'Authorization: Bearer WRONGTOKEN' "
        "-o /dev/null -w '%{http_code}' https://localhost/hidmode"
    ).strip()
    assert code2 == "200", f"a bogus client bearer must be overridden server-side (200), got {code2}"

    # --- (4) the token never leaks into a served response -----------------
    token = machine.succeed("cat /run/pikvm-hidmode/token").strip()
    assert token, "token must exist"
    assert token not in out, "the bearer token must NEVER appear in a served response body"
    hdrs = machine.succeed(f"curl -sk {A} -D - -o /dev/null https://localhost/hidmode")
    assert token not in hdrs, "the bearer token must NEVER appear in served response headers"

    # --- (5) the control page is served to an authed browser --------------
    page = machine.succeed(f"curl -sk {A} https://localhost/hidmode-control")
    assert "HID mode" in page and "/hidmode" in page, \
        "the authed /hidmode-control page must be served"

    # --- (6) the switch drives end-to-end through the proxy ---------------
    # POST is non-blocking; the marker flips after the gadget re-assembles + kvmd
    # restarts. Poll GET (through the proxy) until it reflects ipad.
    post = machine.succeed(f"curl -sk {A} -X POST -H 'Content-Type: application/json' "
                           "-d '{\"mode\":\"ipad\"}' https://localhost/hidmode")
    pd = json.loads(post)
    assert pd.get("ok") is True and pd.get("mode") == "ipad", f"POST switch not accepted: {post!r}"
    machine.wait_until_succeeds(
        f"curl -sk {A} https://localhost/hidmode | grep -q '\"mode\": *\"ipad\"'"
    )

    # --- (7) generated nginx config is valid ------------------------------
    machine.succeed("nginx -t")
  '';
}
