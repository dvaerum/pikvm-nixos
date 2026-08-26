# VM test for the plain-http → https bounce on the PiKVM 443 front-door. The web
# vhost uses nginx `forceSSL`, which emits the stock-faithful :80 server
# (`return 301 https://$host$request_uri;`) — so a browser hitting http://<box>/
# lands on the TLS dashboard instead of a dead port. Guards against a future nginx
# change silently reverting to addSSL (no bounce). @nixos-developer-system boots
# the VM (MCP off to skip onnxruntime; the redirect is independent of it).
{ self, pkgs }:
{
  name = "pikvm-http-redirect";

  nodes.machine = {
    imports = [
      # nginx.nix transitively imports kvmd.nix (→ otg.nix) and
      # mcp-integration.nix — see module-list.nix / Round-2 Phase 2 for why
      # each module now imports its own declarers, which is what makes this
      # list this short.
      ../modules/nginx.nix
      self.nixosModules.mcp-server # declares services.pikvm-mcp (left off)
    ];

    services.pikvm.kvmd.enable = true;
    services.pikvm.kvmd.platform = "auto";
    services.pikvm.otg.enable = true;
    boot.kernelModules = [ "dummy_hcd" ];
    services.pikvm.kvmd.settings.kvmd = {
      msd.type = "disabled";
      atx.type = "disabled";
    };

    services.pikvm.web.enable = true; # 443 dashboard (forceSSL → :80 bounce)
    services.pikvm-mcp.enable = false;

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("kvmd.service")
    machine.wait_for_unit("nginx.service")

    # Plain :80 → 301 to https, preserving the request URI (forceSSL emits the
    # stock `return 301 https://$host$request_uri;`).
    machine.wait_until_succeeds(
        "test $(curl -so /dev/null -w '%{http_code}' http://localhost:80/) = 301"
    )
    hdrs = machine.succeed("curl -sI http://localhost:80/foo/bar")
    low = hdrs.lower()
    assert "location: https://" in low, f"http must 301 to https; got: {hdrs!r}"
    assert "/foo/bar" in hdrs, f"the redirect must preserve the request URI; got: {hdrs!r}"

    # The 443 dashboard still serves: unauthenticated /api/auth/check is 401 but
    # REACHABLE (not 502) — the front-door works, forceSSL didn't break it.
    machine.wait_until_succeeds(
        "test $(curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/auth/check) = 401"
    )
  '';
}
