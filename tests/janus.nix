# VM test for the Janus WebRTC gateway (modules/janus.nix, Phase 3 of
# docs/faithful-pikvm-plan.md). Proves the GENERIC plumbing: the daemon
# starts, loads the ustreamer plugin, listens on the socket nginx already
# expects, and the frontend JS assets serve instead of 404ing.
#
# WHAT THIS DOES NOT PROVE: a real H.264 picture. This VM has no capture
# hardware and the `auto` platform here resolves off a CSI profile anyway —
# see modules/janus.nix's header for why hdmiusb rigs (real appliance
# included) never get --h264-sink from kvmd's own stock config regardless of
# this module. That needs a real CSI-capture appliance and a real browser
# (firefox MCP), tracked separately.
{ self, pkgs }:
{
  name = "pikvm-janus";

  nodes.machine = {
    imports = [
      ../modules/kvmd.nix
      ../modules/otg.nix
      ../modules/nginx.nix
      ../modules/janus.nix
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

    services.pikvm.web.enable = true;
    services.pikvm.janus.enable = true;
    services.pikvm-mcp.enable = false;

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("kvmd.service")
    # kvmd.service has no sd_notify — systemd reports it "active" as soon as
    # the process forks, not once it's actually bound its socket. MEASURED:
    # this genuinely races (passed once, then failed here on a later run with
    # nginx logging "connect() to unix:/run/kvmd/kvmd.sock failed (2: No such
    # file or directory)"). Wait on the real readiness signal, not the
    # systemd unit state — same discipline as the OTG gate's UDC-file wait.
    machine.wait_until_succeeds("test -S /run/kvmd/kvmd.sock", timeout=30)
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("kvmd-janus.service")

    # The daemon actually came up and is still up a moment later — Restart=
    # always would mask a crash-loop as "active" right after start, so check
    # twice with a gap rather than trust the first wait_for_unit alone.
    machine.sleep(2)
    assert "active" in machine.succeed("systemctl is-active kvmd-janus.service"), (
        "kvmd-janus must still be active a moment after start, not crash-looping"
    )

    # It's listening on the EXACT socket nginx's stock config already expects
    # (modules/kvmd.nix's janus-ws upstream) — proves janus.transport
    # .websockets.jcfg's ws_unix path and nginx's upstream path actually agree,
    # not just that both files individually look right.
    machine.wait_until_succeeds("test -S /run/kvmd/janus-ws.sock", timeout=15)

    # /janus/ws sits behind the same auth_request gate as everything else
    # (MEASURED: unauthenticated → 401, from nginx's own auth check, before
    # the request ever reaches the janus-ws upstream) — so 401 here doesn't
    # yet prove Janus answered, only that nginx's routing/auth didn't break.
    # The REAL "something is listening" proof is the socket check above; this
    # just guards against a 502 (nginx couldn't even find the upstream).
    code = machine.succeed(
        "curl -sk -o /dev/null -w '%{http_code}' https://localhost/janus/ws"
    ).strip()
    assert code != "502", f"/janus/ws must not 502 once kvmd-janus is running; got {code}"

    # The frontend assets nginx aliases to /usr/share/janus/javascript on
    # stock now resolve for real (were a hard 404 before this module/the
    # nginx.nix path patch) — but they're still behind the same auth_request
    # gate as the rest of the SPA (MEASURED: an unauthenticated request gets
    # 401, not 200 or 404 — that's stock's own behavior, not a bug), so log
    # in for real first, same as a browser session would.
    machine.succeed(
        "curl -sk -c /tmp/jar.txt -o /dev/null "
        "-d user=admin -d passwd=admin https://localhost/api/auth/login"
    )
    for path in ("/share/js/kvm/janus.js", "/share/js/kvm/adapter.js"):
        out = machine.succeed(
            f"curl -sk -b /tmp/jar.txt -o /dev/null -w '%{{http_code}}' https://localhost{path}"
        ).strip()
        assert out == "200", f"{path} must serve 200 once authenticated, not 404; got {out}"

    # And the served janus.js is specifically OUR shim (proves the nginx
    # alias resolved to janus-web-client, not some stale/empty file) — the
    # named-export re-export line is the shim's signature, not present in
    # Meetecho's own vendored bundle.
    body = machine.succeed("curl -sk -b /tmp/jar.txt https://localhost/share/js/kvm/janus.js")
    assert "export { Janus }" in body, (
        "served janus.js should be the named-export shim, not the raw vendor bundle"
    )
  '';
}
