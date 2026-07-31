# PiKVM web front-door (nginx) — the faithful stock-PiKVM 443 dashboard, plus MCP.
#
# Serves, on a self-signed 443 vhost, the REAL PiKVM web experience by PORTING
# kvmd's own stock nginx config out of the kvmd package (read+patch at build
# time, so it auto-tracks kvmd version bumps rather than drifting from a
# transcription):
#   /            → the static web UI (kvmd's `share/kvmd/web`)
#   /streamer    → ustreamer MJPEG (unix:/run/kvmd/ustreamer.sock)
#   /api, /api/* → kvmd (unix:/run/kvmd/kvmd.sock) — kvmd self-auths (admin/admin)
#   /api/media*  → kvmd-media (unix:/run/kvmd/media.sock)
#   /redfish     → kvmd
#   /mcp         → the PiKVM MCP server (Streamable HTTP)
# The /janus/ws WebRTC blocks are carried verbatim from stock but inert until
# Janus is packaged (Phase 3) — without it they 502/404 and the UI falls back to
# MJPEG. See docs/faithful-pikvm-plan.md.
#
# AUTH is stock: the UI uses nginx `auth_request /auth_check` → kvmd /auth/check;
# /api* + /redfish + /mcp set `auth_request off` and self-authenticate (kvmd's
# {SSHA512} htpasswd, default admin/admin, seeded by modules/kvmd.nix). One
# unified credential store, exactly like stock PiKVM.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.web;

  kvmd = config.services.pikvm.kvmd.package;
  stockNginx = "${kvmd}/share/kvmd/configs.default/nginx";

  # Web Terminal (Phase 2.5, kvmd-webterm): when services.pikvm.web.terminal is
  # on, serve the COMPOSED web root (kvmd UI ∪ the webterm menu icon) and let
  # webterm self-register its nginx via the extras glob-include — exactly how
  # kvmd's own nginx.conf.mako wires extras. Among the extras only webterm ships
  # nginx.ctx-*.conf, so the glob activates only it.
  terminalEnabled = cfg.terminal.enable;
  webterm = pkgs.pikvm.kvmd-webterm;
  webRoot = if terminalEnabled then webterm.webDir else "${kvmd}/share/kvmd/web";

  # The stock server-context config, path-patched: the ONLY Arch path that must
  # change is the static web root (/usr/share/kvmd → the package). The unix-socket
  # upstreams (/run/kvmd/*), the /etc/kvmd/nginx/* includes, /etc/kvmd/web.css and
  # the janus.js aliases are correct/inert as-is. (runCommand reads the real file
  # on the Linux builder; `include`d below rather than readFile so it evals on any
  # host without realising the aarch64 kvmd closure.)
  serverConf = pkgs.runCommand "kvmd-nginx-server.conf" { } ''
    substitute ${stockNginx}/kvmd.ctx-server.conf "$out" \
      --replace-quiet /usr/share/kvmd/web ${webRoot} \
      --replace-quiet /usr/share/kvmd ${kvmd}/share/kvmd
  '';

  # kvmd's nginx includes are self-contained directive snippets with no embedded
  # paths — materialise them verbatim at the absolute path the stock config
  # `include`s (/etc/kvmd/nginx/<f>), straight from the package (bump-proof).
  includeFiles = [
    "loc-proxy.conf"
    "loc-websocket.conf"
    "loc-nobuffering.conf"
    "loc-nocache.conf"
    "loc-login.conf"
    "loc-bigpost.conf"
  ];

  selfSignedDir = "/var/lib/pikvm-nginx";
  certFile = if cfg.tls.certificate != null then cfg.tls.certificate else "${selfSignedDir}/server.crt";
  keyFile = if cfg.tls.certificateKey != null then cfg.tls.certificateKey else "${selfSignedDir}/server.key";
  needsSelfSigned = cfg.tls.certificate == null || cfg.tls.certificateKey == null;
in
{
  options.services.pikvm.web = {
    # DEFAULT-ON, like stock PiKVM (the box is a web KVM out of the box). Set to
    # false to keep the appliance SSH-only (a hardened, headless deployment).
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        The PiKVM web front-door: an nginx TLS (self-signed) 443 vhost serving the
        stock kvmd dashboard (web UI + /api + MJPEG streamer + media) and the MCP
        /mcp endpoint. On by default (faithful to stock PiKVM); set false to keep
        the appliance SSH-only.
      '';
    };

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
        default = config.services.pikvm-mcp.address or "127.0.0.1";
        defaultText = lib.literalExpression "config.services.pikvm-mcp.address";
        description = "Address of the MCP HTTP backend to proxy /mcp to (loopback).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = config.services.pikvm-mcp.port or 3000;
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
          LAN-appliance reality (no ACME/domain). Point at your own cert (a
          runtime secret path for the key — never a store literal) to serve a
          trusted chain.
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
      description = "kvmd's HTTP API unix socket (the nginx `kvmd` upstream target).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Self-signed cert on first boot when the user supplies none. nginx orders
    # after this so the cert exists before it starts.
    systemd.services.pikvm-nginx-selfsigned = lib.mkIf needsSelfSigned {
      description = "Generate a self-signed TLS cert for the PiKVM nginx vhost";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
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

    # kvmd's stock nginx includes, at the absolute path its config expects.
    environment.etc = builtins.listToAttrs (
      map (f: {
        name = "kvmd/nginx/${f}";
        value.source = "${stockNginx}/${f}";
      }) includeFiles
    );

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;

      # kvmd's stock upstreams (all unix sockets: kvmd, ustreamer, media,
      # janus-ws). janus-ws is inert without Janus (Phase 3) — nginx loads it
      # fine and only 502s that route on request. `include`d as a store path so
      # it evals without realising the kvmd closure.
      appendHttpConfig = ''
        include ${stockNginx}/kvmd.ctx-http.conf;
        ${lib.optionalString terminalEnabled "include ${webterm.extrasDir}/*/nginx.ctx-http.conf;"}
      '';

      virtualHosts."pikvm" = {
        serverName = cfg.serverName;
        default = true;
        addSSL = true;
        sslCertificate = certFile;
        sslCertificateKey = keyFile;

        # The stock kvmd dashboard routing (static UI + /api + streamer + media +
        # redfish + auth_request), path-patched, plus our /mcp endpoint.
        extraConfig = ''
          include ${serverConf};
          ${lib.optionalString terminalEnabled "include ${webterm.extrasDir}/*/nginx.ctx-server.conf;"}

          # MCP Streamable-HTTP endpoint (built-in). The MCP self-authenticates
          # (security = "kvmd") so skip nginx auth_request; its responses stream
          # over long-lived HTTP/1.1, so disable buffering + use long timeouts.
          location ${cfg.location} {
            auth_request off;
            proxy_pass http://${cfg.upstream.address}:${toString cfg.upstream.port};
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
          }
        '';
      };
    };

    # nginx (user `nginx`) must reach kvmd's + kvmd-media's unix sockets (0660,
    # owned by those groups). kvmd's stock kvmd-nginx joins these same groups.
    users.users.nginx.extraGroups = [
      "kvmd"
      "kvmd-media"
    ];

    # Order pikvm-mcp strictly AFTER kvmd is serving — kvmd has a latent
    # on_startup socket race and pikvm-mcp's onnxruntime CPU spike, booting in
    # parallel, can starve it into a crash-loop. Wait for the API socket to exist
    # (kvmd only binds it past on_startup). Integration fact (local kvmd) — lives
    # here, not in the standalone MCP module.
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
