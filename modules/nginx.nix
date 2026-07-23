# PiKVM web entrypoint (nginx) — the 443 front-door for kvmd's API and the MCP
# server.
#
# PiKVM's real appliance fronts everything with a TLS nginx on 443 (self-signed
# on the LAN) that reverse-proxies to the individual daemons. That full
# front-end isn't ported yet; this module is its first slice: a 443 vhost that
# reverse-proxies kvmd's HTTP API (`/api/`, from kvmd's unix socket) and the
# MCP Streamable-HTTP endpoint (`/mcp`). The future kvmd UI / ustreamer / Janus
# locations slot into the SAME vhost later.
#
# It TLS-terminates at nginx and proxies plain HTTP to the MCP server on
# loopback (services.pikvm-mcp binds 127.0.0.1:3000 by default). Off unless
# `services.pikvm.mcpProxy.enable = true`.
#
# AUTH is intentionally NOT done here. The appliance uses UNIFIED auth: the MCP
# server runs `services.pikvm-mcp.security = "kvmd"`, which validates each
# client's PiKVM credentials against kvmd (/api/auth/check) — the SAME login as
# the PiKVM web UI, one credential store (/etc/kvmd/htpasswd). nginx therefore
# only TLS-terminates + proxies; adding an nginx-level auth_basic here would be
# a second, non-unified password (kvmd's {SSHA512} htpasswd isn't even
# nginx-auth_basic-readable). A forker who wants edge auth can add their own
# nginx snippet.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.mcpProxy;
  mcp = config.services.pikvm-mcp or { };

  # Where the self-signed cert lands when the user supplies none. Kept off the
  # Nix store (a private key must never be world-readable in /nix/store).
  selfSignedDir = "/var/lib/pikvm-nginx";
  certFile = if cfg.tls.certificate != null then cfg.tls.certificate else "${selfSignedDir}/server.crt";
  keyFile = if cfg.tls.certificateKey != null then cfg.tls.certificateKey else "${selfSignedDir}/server.key";
  needsSelfSigned = cfg.tls.certificate == null || cfg.tls.certificateKey == null;
in
{
  options.services.pikvm.mcpProxy = {
    enable = lib.mkEnableOption ''
      the nginx TLS reverse-proxy that exposes the PiKVM MCP server on port 443
      at ${cfg.location or "/mcp"} (the "point your agent at the /mcp endpoint" UX)'';

    location = lib.mkOption {
      type = lib.types.str;
      default = "/mcp";
      description = "Path on the 443 vhost where the MCP Streamable HTTP endpoint is served.";
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      default = "_";
      description = "nginx `server_name` for the PiKVM vhost (default: catch-all).";
    };

    upstream = {
      address = lib.mkOption {
        type = lib.types.str;
        default = mcp.address or "127.0.0.1";
        defaultText = lib.literalExpression "config.services.pikvm-mcp.address";
        description = "Address of the MCP HTTP backend to proxy to (loopback).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = mcp.port or 3000;
        defaultText = lib.literalExpression "config.services.pikvm-mcp.port";
        description = "Port of the MCP HTTP backend.";
      };
    };

    tls = {
      certificate = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          TLS certificate (PEM). When null (default) a self-signed cert is
          generated at first boot into ${selfSignedDir} — matching PiKVM's
          LAN-appliance reality (no ACME/domain). Point this at the shared
          PiKVM cert once the full kvmd-nginx front-end is ported.
        '';
      };
      certificateKey = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "TLS private key (PEM). Generated alongside the self-signed cert when null.";
      };
    };

    kvmdApiSocket = lib.mkOption {
      type = lib.types.path;
      default = "/run/kvmd/kvmd.sock";
      description = ''
        kvmd's HTTP API unix socket, reverse-proxied on this vhost under
        `/api/`. This is the first slice of the kvmd-nginx front-door: it gives
        the MCP server (services.pikvm-mcp, security = "kvmd") an HTTP route to
        kvmd at https://localhost/api/auth/check — kvmd itself listens only on
        this socket, not TCP. kvmd enforces its own auth on /api, so exposing it
        on the vhost is safe. The default is kvmd's stock socket path.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Generate a self-signed cert on first boot when the user supplies none.
    # nginx orders after this so the cert exists before it starts.
    systemd.services.pikvm-nginx-selfsigned = lib.mkIf needsSelfSigned {
      description = "Generate a self-signed TLS cert for the PiKVM nginx vhost";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as the nginx user so the cert dir + files are nginx-owned —
        # otherwise the 0700 root:root StateDirectory blocks nginx (which loads
        # the cert as user `nginx`) from traversing it, failing its config test.
        User = "nginx";
        Group = "nginx";
        StateDirectory = "pikvm-nginx";
        StateDirectoryMode = "0700";
      };
      path = [ pkgs.openssl ];
      script = ''
        set -eu
        crt="${certFile}"
        key="${keyFile}"
        if [ -s "$crt" ] && [ -s "$key" ]; then
          exit 0
        fi
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout "$key" -out "$crt" -days 3650 \
          -subj "/CN=pikvm" \
          -addext "subjectAltName=DNS:pikvm,DNS:localhost,IP:127.0.0.1"
        chmod 0640 "$key"
      '';
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      # kvmd listens only on a unix socket; front it so its HTTP API is
      # reachable over TCP/TLS (the MCP server's control calls + the
      # security="kvmd" /api/auth/check round-trip both go via https://localhost).
      upstreams.pikvm-kvmd.servers."unix:${cfg.kvmdApiSocket}" = { };

      virtualHosts."pikvm" = {
        serverName = cfg.serverName;
        default = true;
        addSSL = true;
        sslCertificate = certFile;
        sslCertificateKey = keyFile;

        # kvmd HTTP API (auth, control, snapshot). kvmd enforces its own auth
        # here — nginx just TLS-terminates + proxies to the socket. kvmd serves
        # its routes at the socket ROOT (/auth/check, /hid, …) with NO /api
        # prefix; the /api/ is a front-door convention we must STRIP. The
        # trailing slash on proxyPass makes nginx replace the matched "/api/"
        # with "/", so /api/auth/check → kvmd's /auth/check (else kvmd 404s).
        locations."/api/".proxyPass = "http://pikvm-kvmd/";

        locations.${cfg.location} = {
          proxyPass = "http://${cfg.upstream.address}:${toString cfg.upstream.port}";
          # MCP Streamable HTTP is long-lived (POST/GET/DELETE /mcp with
          # SSE-style streamed responses over plain HTTP/1.1 — not a WebSocket
          # upgrade). Disable response buffering so streamed events flush
          # immediately, and use generous timeouts so idle streams aren't cut.
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
          '';
        };
      };
    };

    # kvmd's API socket is 0660 kvmd:kvmd, so nginx must be in the kvmd group
    # to connect to it (the /api/ upstream). services.nginx runs as user
    # `nginx`; add it to `kvmd` (the group modules/kvmd.nix defines).
    users.users.nginx.extraGroups = [ "kvmd" ];

    # Order pikvm-mcp strictly AFTER kvmd is actually serving. kvmd has a
    # latent on_startup socket race; pikvm-mcp's onnxruntime startup CPU load,
    # if it boots in parallel, starves kvmd's boot so kvmd keeps losing that
    # race → crash-loop. kvmd only binds its API socket once it's past
    # on_startup, so waiting for the socket to EXIST guarantees kvmd is out of
    # its vulnerable window before mcp's load lands. This is an INTEGRATION
    # fact (local kvmd) — it belongs here, not in the standalone MCP module
    # (which can target a remote PiKVM with no local kvmd.service).
    systemd.services.pikvm-mcp = lib.mkIf (config.services.pikvm-mcp.enable or false) {
      after = [ "kvmd.service" ];
      wants = [ "kvmd.service" ];
      serviceConfig.ExecStartPre = pkgs.writeShellScript "wait-for-kvmd-sock" ''
        for _ in $(seq 1 120); do
          [ -S ${cfg.kvmdApiSocket} ] && exit 0
          sleep 1
        done
        echo "kvmd API socket ${cfg.kvmdApiSocket} never appeared" >&2
        exit 1
      '';
    };

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
