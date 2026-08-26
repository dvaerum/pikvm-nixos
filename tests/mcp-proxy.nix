# End-to-end VM test for UNIFIED auth (U2): prove the SAME PiKVM login works on
# the MCP /mcp endpoint, through the real nginx TLS front-door and a real kvmd.
#
# Boots kvmd (unix socket) + nginx (fronting kvmd /api AND MCP /mcp on 443/TLS)
# + services.pikvm-mcp with security = "kvmd" (validates each client's PiKVM
# creds against kvmd's /api/auth/check via https://localhost). A real user is
# seeded into /etc/kvmd/htpasswd and we assert that exact login authorizes /mcp
# on BOTH surfaces — no separate MCP password anywhere:
#   (a) HTTP Basic header at connect;
#   (b) header-less connect + the in-band `login` tool (allowToolLogin = true),
#       with tools/list gating: only `login` until authenticated.
# A second node (allowToolLogin = false) proves the OFF-parity: header-less is
# just 401, identical to plain header auth.
#
# @nixos-developer-system runs the booted VM. Uses { self, pkgs } like
# kvmd-services.nix: self.nixosModules.mcp-server provides services.pikvm-mcp.
{ self, pkgs }:
let
  # A full front-door node, parameterised only by whether the in-band login
  # tool is enabled. Both nodes share kvmd + nginx + mcp(security=kvmd).
  # A throwaway self-signed CA/server cert for localhost, built at eval time
  # (test-only — a real deployment points certificateKey at a sops/agenix
  # secret). Used on the `off` node to prove the bring-your-own-cert path;
  # `machine` stays on the self-signed-at-first-boot default.
  testCert = pkgs.runCommand "pikvm-mcpproxy-testcert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $out/key.pem -out $out/cert.pem \
      -days 3650 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
  '';

  mkNode = allowToolLogin: {
    imports = [
      # nginx.nix transitively imports kvmd.nix (→ otg.nix) and
      # mcp-integration.nix — see module-list.nix / Round-2 Phase 2 for why
      # each module now imports its own declarers, which is what makes this
      # list this short.
      ../modules/nginx.nix
      self.nixosModules.mcp-server # services.pikvm-mcp
    ];

    services.pikvm.kvmd.enable = true;
    services.pikvm.kvmd.platform = "auto";
    # platform=auto drives the OTG HID; kvmd crash-loops on missing
    # /dev/kvmd-hid-* without a bound gadget. dummy_hcd gives a virtual UDC so
    # the gadget binds in the VM (same as kvmd-services.nix). Orthogonal to the
    # mcp ordering — kvmd needs this to come up at all under auto.
    services.pikvm.otg.enable = true;
    boot.kernelModules = [ "dummy_hcd" ];

    # kvmd's on_startup crash-loops in a generic VM without these: msd.type=otg
    # writes the Pi vendor configfs attr inquiry_string_cdrom (EACCES), and
    # atx.type=gpio opens /dev/gpiochip0 (absent → FileNotFoundError). The
    # appliance keeps both — this is a VM-hardware accommodation only.
    services.pikvm.kvmd.settings.kvmd = {
      msd.type = "disabled";
      atx.type = "disabled";
    };

    services.pikvm.web.enable = true; # 443 front-door: kvmd /api + /mcp

    services.pikvm-mcp = {
      enable = true;
      host = "https://localhost"; # reach kvmd via our own nginx /api (self-signed)
      verifySsl = false;
      target = "desktop";
      security = "kvmd"; # UNIFIED auth: validate client creds against kvmd
      inherit allowToolLogin;
    };

    # onnxruntime (pikvm-mcp) co-resident with kvmd + nginx is tight at 2048.
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 4096;
  };
in
{
  name = "pikvm-mcp-proxy";

  nodes.machine = mkNode true; # header + tool-login; self-signed cert (default)
  nodes.off =
    { pkgs, ... }:
    {
      # header only (OFF-parity) + a bring-your-own TLS cert (BYO-cert path),
      # where the private KEY is a RUNTIME path (NOT a /nix/store path) — the
      # faithful sops-nix / agenix scenario: a secret decrypted at boot into
      # /run, owned by nginx, that nginx serves verbatim (never store-copied).
      imports = [ (mkNode false) ];

      # The public cert may live in the store (it's not secret); the KEY is
      # materialized at boot to a runtime path owned by nginx. In a real deploy
      # this file IS config.sops.secrets."…".path / config.age.secrets."…".path
      # — here a oneshot stands in for sops-install-secrets / agenix, which
      # decrypt during activation (before nginx). We add the explicit ordering
      # a systemd-mode secret would need, to prove nginx waits for the key.
      systemd.services.pikvm-byo-key = {
        description = "Materialize the BYO TLS key at a runtime path (sops/agenix stand-in)";
        wantedBy = [ "multi-user.target" ];
        before = [ "nginx.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.coreutils ];
        script = ''
          mkdir -p /run/pikvm-byo-tls
          install -m0400 -o nginx -g nginx ${testCert}/key.pem /run/pikvm-byo-tls/key.pem
        '';
      };
      systemd.services.nginx = {
        after = [ "pikvm-byo-key.service" ];
        wants = [ "pikvm-byo-key.service" ];
      };

      services.pikvm.web.tls.certificate = "${testCert}/cert.pem";
      # RUNTIME path — not "${testCert}/key.pem" — so the key never enters the store.
      services.pikvm.web.tls.certificateKey = "/run/pikvm-byo-tls/key.pem";
    };

  testScript = ''
    import json

    start_all()

    INIT = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "vmtest", "version": "1"}},
    })
    ACCEPT = "-H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json'"

    # MCP Streamable HTTP may answer as plain JSON or an SSE frame; pull the
    # JSON-RPC object out of either.
    def mcp_json(raw):
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                line = line[5:].strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    pass
        return {}

    def setup(node):
        node.wait_for_unit("kvmd.service")
        node.wait_for_unit("nginx.service")
        node.wait_for_unit("pikvm-mcp.service")
        # nginx must reach kvmd's socket (nginx is in the kvmd group). kvmd's own
        # auth answers on /api — unauthenticated /api/auth/check is 401 but
        # REACHABLE (not 502), proving the socket front-door works.
        node.wait_until_succeeds(
            "test $(curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/auth/check) = 401"
        )
        # Seed a real PiKVM user. `add` creates (create=True); `-i` reads ONE
        # line from stdin (no tty in the VM). Confirmed vs kvmd 4.188.
        node.succeed("printf 'secretpw\\n' | ${pkgs.pikvm.kvmd}/bin/kvmd-htpasswd add alice -i")

    def mcp_init(node, auth=""):
        a = f"-u {auth}" if auth else ""
        code = node.succeed(
            f"curl -sk -D /tmp/h -o /tmp/b -w '%{{http_code}}' {ACCEPT} {a} "
            f"-X POST https://localhost/mcp -d '{INIT}'"
        ).strip()
        return code, node.succeed("cat /tmp/h"), node.succeed("cat /tmp/b")

    def session_id(headers):
        for line in headers.splitlines():
            if line.lower().startswith("mcp-session-id:"):
                return line.split(":", 1)[1].strip()
        return ""

    def mcp_call(node, method, params, sid):
        body = json.dumps({"jsonrpc": "2.0", "id": 2, "method": method, "params": params})
        return node.succeed(
            f"curl -sk {ACCEPT} -H 'Mcp-Session-Id: {sid}' "
            f"-X POST https://localhost/mcp -d '{body}'"
        )

    def tool_names(node, sid):
        raw = mcp_call(node, "tools/list", {}, sid)
        obj = mcp_json(raw)
        return [t.get("name") for t in obj.get("result", {}).get("tools", [])]

    # tools/call → (isError, first-content-text). Shapes confirmed vs e8e9547.
    def call_tool(node, name, args, sid):
        obj = mcp_json(mcp_call(node, "tools/call", {"name": name, "arguments": args}, sid))
        res = obj.get("result", {})
        content = res.get("content", [])
        text = content[0].get("text", "") if content else ""
        return bool(res.get("isError", False)), text

    setup(machine)
    setup(off)

    # === TLS: bring-your-own cert vs self-signed default ====================
    # `off` supplied tls.certificate/certificateKey → nginx serves OUR cert
    # (curl validates the chain against our CA, no -k) and the self-signed
    # generator must NOT have run. `machine` supplied none → it self-signs.
    off.succeed(
        "${pkgs.curl}/bin/curl --cacert ${testCert}/cert.pem -o /dev/null -w '%{http_code}'"
        " https://localhost/api/auth/check | grep -qE '401|403'"
    )
    off.fail("systemctl is-active pikvm-nginx-selfsigned.service")
    machine.succeed("systemctl is-active pikvm-nginx-selfsigned.service")

    # --- runtime-path key (the sops/agenix guarantee) ----------------------
    # The KEY nginx serves is a RUNTIME path, NOT a /nix/store copy. This is the
    # whole point of pointing certificateKey at a secret manager: the private
    # key is passed to nginx verbatim and never lands in the world-readable
    # store. Prove the rendered nginx config references /run (and NOT the store)
    # for the key, that the file is owned by nginx (readable), and that nginx
    # started only after the secret was materialized.
    # nginx's effective config lives in the store (started as
    # `nginx -c /nix/store/…-nginx.conf`), not /etc — resolve it from the unit.
    nginx_conf = off.succeed(
        "systemctl show -p ExecStart --value nginx "
        "| grep -oE '/nix/store/[^ ]+-nginx\\.conf' | head -n1"
    ).strip()
    off.succeed(f"grep -qE 'ssl_certificate_key +/run/pikvm-byo-tls/key.pem;' {nginx_conf}")
    off.fail(f"grep -qE 'ssl_certificate_key +/nix/store' {nginx_conf}")
    off.succeed("test \"$(stat -c '%U' /run/pikvm-byo-tls/key.pem)\" = nginx")
    off.succeed("systemctl is-active pikvm-byo-key.service")

    # === HEADER auth (strict, per MCP PR #18 / Option A): present header ====
    # A PRESENT Basic header is ALWAYS validated against kvmd — wrong → 401,
    # valid → 200 — on BOTH nodes, regardless of allowToolLogin. Only an ABSENT
    # header on the machine node (allowToolLogin=true) opens a pre-auth session
    # (asserted as path (b) below).
    for node in (machine, off):
        code, _, _ = mcp_init(node, "alice:wrongpw")
        assert code == "401", f"wrong PiKVM creds must be rejected, got {code}"
        code, hdrs, _ = mcp_init(node, "alice:secretpw")
        assert code == "200", f"valid PiKVM login must authorize /mcp, got {code}"
        assert session_id(hdrs), "authorized initialize must return a session id"

    # === ABSENT-header outcome is node-specific =============================
    # allowToolLogin=false → a header-less initialize is rejected (401). The
    # machine node's header-less → 200 pre-auth is asserted as path (b) below.
    code, _, _ = mcp_init(off)
    assert code == "401", f"no-creds must be 401 when allowToolLogin is off, got {code}"

    # === TOOL-LOGIN path (b) — machine (allowToolLogin=true), header-less ====
    # Payload shapes confirmed against e8e9547 by @nixos-developer-system:
    # tools/call → result.isError + result.content[0].text; gating probe tool is
    # `pikvm_version` (device-free). With the toggle ON, a header-less
    # initialize opens a PRE-AUTH session (200, NOT 401) that sees only `login`.
    code, hdrs, _ = mcp_init(machine)  # header-less initialize → pre-auth session
    assert code == "200", f"header-less initialize should open a pre-auth session, got {code}"
    sid = session_id(hdrs)
    assert sid, "pre-auth session must have a session id"

    # Pre-auth: tools/list exposes EXACTLY the login tool (full set hidden).
    assert tool_names(machine, sid) == ["login"], "pre-auth tools/list must show ONLY login"

    # Pre-auth: a real tool is gated with an "authentication required" error.
    err, text = call_tool(machine, "pikvm_version", {}, sid)
    assert err and "authentication required" in text, f"pre-auth tool must be gated: {text!r}"

    # login with WRONG creds → isError "authentication failed"; session stays gated.
    err, text = call_tool(machine, "login", {"username": "alice", "password": "wrongpw"}, sid)
    assert err and "authentication failed" in text, f"wrong login must be rejected: {text!r}"
    err, _ = call_tool(machine, "pikvm_version", {}, sid)
    assert err, "wrong login must NOT unlock the session"

    # login with the REAL PiKVM creds → success, session authorized.
    err, text = call_tool(machine, "login", {"username": "alice", "password": "secretpw"}, sid)
    assert (not err) and "Authentication successful" in text, f"valid login must authorize: {text!r}"

    # The previously-gated real tool now succeeds on the same session.
    err, _ = call_tool(machine, "pikvm_version", {}, sid)
    assert not err, "after login, real tools must be reachable"

    # Idempotent: a second login on an authed session says so.
    err, text = call_tool(machine, "login", {"username": "alice", "password": "secretpw"}, sid)
    assert (not err) and "Already authenticated" in text, f"2nd login should be idempotent: {text!r}"
  '';
}
