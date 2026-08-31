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
#   /local-streamer → ustreamer MJPEG, UNAUTHENTICATED but loopback-only
#                  (127.0.0.1/::1 allowlist, `deny all` otherwise) — for an
#                  on-box client that needs the stream without depending on
#                  kvmd's admin credentials (see services.pikvm.web
#                  .localStreamerBypass below). Off by default.
# The /janus/ws WebRTC blocks are carried verbatim from stock; the janus.js /
# adapter.js static aliases are path-patched the same way the web root is
# (see serverConf below — pkgs.pikvm.janus-web-client, added 2026-08-20).
# Whether they actually SERVE anything live depends on services.pikvm.janus
# .enable (modules/janus.nix) — without it, /janus/ws still 502s (nothing
# listens on the janus-ws upstream) and the UI falls back to MJPEG, same as
# before. See docs/faithful-pikvm-plan.md.
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

  # Front-door "extras" composition. The stock landing dashboard renders one tile
  # per advertised extra (kvmd.info.extras) generically, and nginx self-registers
  # each extra's nginx snippets via a glob — exactly how kvmd's own
  # nginx.conf.mako wires extras. We advertise the base (kvmd's extras minus the
  # unpackaged ipmi/vnc daemons) ∪ each enabled front-door extra, composed ONCE
  # here (the front-door owns it) so kvmd.info.extras + the served web root + the
  # nginx glob all see a single dir:
  #   • webterm (Phase 2.5): the in-session "• Term" toolbar button — ships
  #     nginx.ctx-*.conf (self-registers /extras/webterm/ttyd) + a menu icon.
  #   • hidmode (#51 option-b): a LANDING-dashboard tile linking to /hidmode-control.
  #     The SUPPORTED generic extras mechanism (identical to ipmi/vnc), ZERO
  #     web-tree patch, auto-tracks kvmd upgrades; it keeps the #42 control page's
  #     confirm + non-optimistic poll + #44 next-boot drift warning. Manifest+icon
  #     only (no nginx snippet); tile visibility gated on the endpoint unit via the
  #     manifest `daemon:`. Rejected alternatives (in-session fork B, GPIO toggle C)
  #     are recorded in docs/decisions/0002.
  terminalEnabled = cfg.terminal.enable;
  hidModeControlEnabled = cfg.hidModeControl.enable;
  webterm = pkgs.pikvm.kvmd-webterm;

  # The hidmode landing-tile extra: manifest (scanned via kvmd.info.extras) + icon
  # (served under the web root at the path the manifest references). Data-only.
  hidmodeExtra = pkgs.runCommand "kvmd-extra-hidmode" { } ''
    install -Dm644 ${./hidmode-extra/manifest.yaml} "$out/share/kvmd/extras/hidmode/manifest.yaml"
    install -Dm644 ${./hidmode-extra/hidmode.svg}   "$out/share/kvmd/web/extras/hidmode/hidmode.svg"
  '';

  # kvmd's share dir is a read-only store path (can't drop extras into it), so we
  # symlinkJoin its extras/web with each enabled front-door extra's subtree — no
  # kvmd package patch needed. `kvmd-extras` is the filtered base (ipmi/vnc out).
  composedExtras = pkgs.symlinkJoin {
    name = "kvmd-extras-composed";
    paths =
      [ "${pkgs.pikvm.kvmd-extras}" ]
      ++ lib.optional terminalEnabled "${webterm}/share/kvmd/extras"
      ++ lib.optional hidModeControlEnabled "${hidmodeExtra}/share/kvmd/extras";
  };
  composedWeb = pkgs.symlinkJoin {
    name = "kvmd-web-composed";
    paths =
      [ "${kvmd}/share/kvmd/web" ]
      ++ lib.optional terminalEnabled "${webterm}/share/kvmd/web"
      ++ lib.optional hidModeControlEnabled "${hidmodeExtra}/share/kvmd/web";
  };
  webRoot = composedWeb;

  # The stock server-context config, path-patched. Two Arch paths must change:
  # the static web root (/usr/share/kvmd → the package) and, since 2026-08-20,
  # the janus.js/adapter.js aliases (/usr/share/janus/javascript → the
  # janus-web-client package — MEASURED: that path does not and never will
  # exist on NixOS, so leaving it unpatched isn't "inert", it's a permanent
  # 404 even once Janus itself is running). The unix-socket upstreams
  # (/run/kvmd/*) and the /etc/kvmd/nginx/* includes ARE correct as-is.
  # (runCommand reads the real file on the Linux builder; `include`d below
  # rather than readFile so it evals on any host without realising the
  # aarch64 kvmd closure.)
  serverConf = pkgs.runCommand "kvmd-nginx-server.conf" { } ''
    substitute ${stockNginx}/kvmd.ctx-server.conf "$out" \
      --replace-quiet /usr/share/kvmd/web ${webRoot} \
      --replace-quiet /usr/share/kvmd ${kvmd}/share/kvmd \
      --replace-quiet /usr/share/janus/javascript ${pkgs.pikvm.janus-web-client}/share/janus-web-client
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
  # The web Terminal is part of the web front-door: own its module here so the
  # services.pikvm.web.terminal option is declared for ANY nginx consumer
  # (the appliance AND tests that import nginx.nix alone, e.g. tests/mcp-proxy.nix
  # which references cfg.terminal via the config below).
  imports = [
    ./webterm.nix
    ./hidmode-web.nix
    # mcp-integration.nix: reads services.pikvm.mcp.*. kvmd.nix: this module
    # writes kvmd.settings.kvmd.info.extras (below) — see module-list.nix /
    # Round-2 Phase 2 for why every module now imports its own declarers.
    ./mcp-integration.nix
    ./kvmd.nix
  ];

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
        default =
          if config.services.pikvm.mcp.address != null then config.services.pikvm.mcp.address else "127.0.0.1";
        defaultText = lib.literalExpression "config.services.pikvm.mcp.address";
        description = "Address of the MCP HTTP backend to proxy /mcp to (loopback).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = if config.services.pikvm.mcp.port != null then config.services.pikvm.mcp.port else 3000;
        defaultText = lib.literalExpression "config.services.pikvm.mcp.port";
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

    localStreamerBypass.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Serve ustreamer's MJPEG output at `/local-streamer`, UNAUTHENTICATED,
        gated instead by an nginx `allow 127.0.0.1; allow ::1; deny all;`
        IP-allowlist — real security, just a different kind than kvmd's admin
        credentials, and one that can't silently break when an operator
        rotates their kvmd password (task_c9df75066f71, 2026-08-31: found on
        real hardware that stock `/streamer` requiring kvmd auth broke
        local-display's mjpeg-mode client outright — it carried zero
        credentials). Does NOT touch stock `/streamer`'s own auth requirement;
        this is a separate, additive location. Off by default; auto-enabled
        by services.pikvm.localDisplay whenever it's enabled — not meant to
        be set directly except by some other future on-box, loopback-only
        consumer with the identical need.
      '';
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

    # Advertise the composed extras to kvmd: the landing dashboard renders a tile
    # per extra (ipmi/vnc filtered out by kvmd-extras; webterm/hidmode composed in)
    # and the nginx glob above self-registers each extra's snippets. Set here (the
    # front-door composition owner) so webterm + hidmode land in ONE value rather
    # than conflicting defs; overrides the base default in modules/kvmd.nix.
    services.pikvm.kvmd.settings.kvmd.info.extras = "${composedExtras}";

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;

      # kvmd's stock upstreams (all unix sockets: kvmd, ustreamer, media,
      # janus-ws). janus-ws is inert without Janus (Phase 3) — nginx loads it
      # fine and only 502s that route on request. `include`d as a store path so
      # it evals without realising the kvmd closure.
      appendHttpConfig = ''
        include ${stockNginx}/kvmd.ctx-http.conf;
        ${lib.optionalString terminalEnabled "include ${composedExtras}/*/nginx.ctx-http.conf;"}
      '';

      virtualHosts."pikvm" = {
        serverName = cfg.serverName;
        default = true;
        # forceSSL (not addSSL) so plain :80 gets a stock-faithful redirect
        # server — `return 301 https://$host$request_uri;` — instead of serving
        # the dashboard over http. Matches kvmd's nginx.conf.mako :80 block
        # (the https_enabled branch); addSSL served both 80 and 443 with no bounce.
        forceSSL = true;
        sslCertificate = certFile;
        sslCertificateKey = keyFile;

        # The stock kvmd dashboard routing (static UI + /api + streamer + media +
        # redfish + auth_request), path-patched, plus our /mcp endpoint.
        extraConfig = ''
          include ${serverConf};
          ${lib.optionalString terminalEnabled "include ${composedExtras}/*/nginx.ctx-server.conf;"}

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

          ${lib.optionalString cfg.localStreamerBypass.enable ''
            # Loopback-only ustreamer MJPEG, no kvmd auth — see the
            # localStreamerBypass option doc for why. Mirrors stock's own
            # /streamer location's rewrite/proxy shape exactly, just under a
            # distinct path with allow/deny + auth_request off instead of the
            # inherited server-level `auth_request /auth_check;`.
            location /local-streamer {
              allow 127.0.0.1;
              allow ::1;
              deny all;
              auth_request off;
              rewrite ^/local-streamer$ / break;
              rewrite ^/local-streamer\?(.*)$ ?$1 break;
              rewrite ^/local-streamer/(.*)$ /$1 break;
              proxy_pass http://ustreamer;
              include /etc/kvmd/nginx/loc-proxy.conf;
              include /etc/kvmd/nginx/loc-nobuffering.conf;
            }
          ''}
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
    # systemd.services.<name> is a generic, always-valid option path (unlike
    # services.pikvm-mcp.* itself), so this write is safe as a bare mkIf even
    # when services.pikvm-mcp isn't declared — no structural guard needed here.
    systemd.services.pikvm-mcp = lib.mkIf config.services.pikvm.mcp.enabled {
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

    # 80 for the http→https redirect server (forceSSL), 443 for the dashboard.
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
