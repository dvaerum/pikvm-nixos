# VM test for the #51 dashboard HID-mode control (modules/hidmode-web.nix) — the
# 443 front-door half. Proves the SECURITY shape, not just reachability:
#   - the /hidmode proxy + /hidmode-control page inherit the dashboard auth
#     (refused without a session — no anonymous switch path);
#   - a dashboard-authed request reaches the loopback endpoint ONLY because the
#     proxy injects the bearer SERVER-SIDE (non-vacuous: dashboard-auth alone
#     does not satisfy the endpoint's bearer check);
#   - the client CANNOT smuggle its own Authorization (the proxy overrides it);
#   - the token never appears in a served response;
#   - the switch drives end-to-end through the proxy (POST → assembled mode flips);
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
      ../modules/runtime-paths.nix
      ../modules/deployment.nix # hidMode.default's own default reads this (Phase 4)
      ../modules/system/auto-upgrade.nix # deployment.nix's config unconditionally targets this option
      ../modules/mcp-integration.nix
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
    # Dashboard auth via a SESSION COOKIE — the real browser path (the control
    # page fetches with credentials:same-origin). Crucially this leaves the
    # Authorization header FREE for the proxy to inject the bearer server-side;
    # basic-auth (-u) would occupy Authorization and collide with the bearer
    # (and curl's -H Authorization silently overrides -u). Log in once, reuse the
    # cookie jar for every authed request.
    machine.succeed(
        "curl -sk -c /tmp/cj -X POST https://localhost/api/auth/login "
        "-d 'user=alice&passwd=secretpw'"
    )
    A = "-b /tmp/cj"

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
    import re
    data = json.loads(out)
    assert data.get("ok") is True and data.get("mode") in ("desktop", "ipad"), \
        f"authed GET /hidmode must reach the endpoint (server-side bearer); got {out!r}"
    assert data["mode"] == "desktop", f"fresh install should seed desktop; got {data['mode']}"

    # --- (2b) the DRIFT signal reaches through the 443 proxy ---------------
    # The assembled-mode endpoint reports requested/observed/settled; the proxy
    # passes the body verbatim (no sub_filter), so a dashboard consumer can detect
    # a failed switch (settled & requested != observed). Assert the fields survive
    # the proxy — this is what the control page's drift indicator consumes, and
    # what the pre-assembled-endpoint base could NOT surface. Non-vacuous: an
    # endpoint/proxy that dropped these would leave drift invisible to the UI.
    for k in ("requested", "observed", "settled"):
        assert k in data, f"443 /hidmode must expose '{k}' for drift detection; got {out!r}"
    assert data["observed"] == data["mode"], \
        f"'mode' must equal 'observed' (the assembled gadget); got {out!r}"

    # --- (3) the client cannot smuggle / override the bearer --------------
    # Cookie-authed (so the dashboard auth_request is satisfied via the cookie,
    # NOT the Authorization header), the client then sends a bogus
    # `Authorization: Bearer X`. It must be OVERRIDDEN by the server-side bearer,
    # so the request still succeeds — proving `proxy_set_header Authorization`
    # wins and the client's header never reaches the loopback endpoint.
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
    # The shipped page must carry the drift-surfacing logic (reads requested/observed/
    # settled and explains a failed switch), not just poll `mode`. Assert the markup
    # + logic are present so a regression that strips them fails here.
    assert 'id="drift"' in page and "renderDrift" in page, \
        "the control page must include the drift indicator (id=drift + renderDrift)"
    assert "will boot into" in page, \
        "the control page must warn which mode the box will boot into on requested != observed"

    # --- (5b) option-b: the HID-mode landing-dashboard tile ---------------
    # The stock landing dashboard renders a generic tile per advertised extra from
    # /api/info?fields=extras (icon + path + name), gated visible on the extra's
    # daemon being active — the SUPPORTED, zero-web-tree-patch mechanism (like
    # ipmi/vnc). Assert our hidmode extra is advertised + live, and that its icon +
    # the trailing-slash tile target both resolve (index/main.js appends "/" to the
    # manifest path). See docs/decisions/0002.
    extras = json.loads(machine.succeed(f"curl -sk {A} 'https://localhost/api/info?fields=extras'"))
    hidmode = extras["result"]["extras"].get("hidmode")
    assert hidmode is not None, f"the hidmode extra must be advertised to the dashboard; got {extras!r}"
    assert hidmode.get("path") == "hidmode-control", f"hidmode tile must link to hidmode-control; got {hidmode!r}"
    assert (hidmode.get("enabled") or hidmode.get("started")), \
        f"hidmode tile must be visible (its endpoint daemon active); got {hidmode!r}"
    icon = machine.succeed(f"curl -sk {A} https://localhost/extras/hidmode/hidmode.svg")
    assert "<svg" in icon, "the hidmode tile icon must be served from the composed web root"
    # -L: the tile's slash URL 301-canonicalizes to /hidmode-control; a real
    # browser (it-03400 Firefox) follows it transparently, and so must curl here.
    page_slash = machine.succeed(f"curl -skL {A} https://localhost/hidmode-control/")
    assert "HID mode" in page_slash, "the trailing-slash tile URL must serve the control page (via 301)"

    # --- (6) the switch drives end-to-end through the proxy ---------------
    # POST is non-blocking; the assembled gadget flips after it re-assembles + kvmd
    # restarts. Poll GET (through the proxy) until `mode` reflects ipad.
    post = machine.succeed(f"curl -sk {A} -X POST -H 'Content-Type: application/json' "
                           "-d '{\"mode\":\"ipad\"}' https://localhost/hidmode")
    pd = json.loads(post)
    assert pd.get("ok") is True and pd.get("mode") == "ipad", f"POST switch not accepted: {post!r}"
    machine.wait_until_succeeds(
        f"curl -sk {A} https://localhost/hidmode | grep -q '\"mode\": *\"ipad\"'"
    )

    # --- (7) generated nginx config is valid ------------------------------
    # nginx isn't on the machine's default PATH — parse the unit's ExecStart for
    # the real store binary + config path and validate THAT (same approach as
    # webterm.nix step 1b), so we test the actual generated config, not a bare
    # PATH lookup that exits 127.
    execstart = machine.succeed("systemctl cat nginx.service | grep -m1 -oE 'ExecStart=.*'")
    m = re.search(r"ExecStart=(\S+).* -c (\S+)", execstart)
    assert m, f"couldn't parse nginx ExecStart: {execstart!r}"
    machine.succeed(f"{m.group(1)} -t -c {m.group(2)}")
  '';
}
