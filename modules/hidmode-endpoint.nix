# The authenticated loopback HID-mode endpoint — the MCP-facing half of the
# runtime iPad/desktop switch (#51). The privileged executor + templated root
# units `pikvm-hidmode@<mode>.service` + the polkit rule live in hidmode.nix.
# Same split as hid-recovery{,-endpoint}.nix.
#
# Flow: the MCP server reads current mode via GET /hidmode and requests a switch
# via POST /hidmode {"mode": "ipad"} + a bearer token; we validate the token and
# `systemctl start --no-block pikvm-hidmode@<mode>.service` (polkit grants our
# user start-only on those units — no sudo/setuid). We also wire
# PIKVM_HIDMODE_URL / PIKVM_HIDMODE_TOKEN into services.pikvm-mcp so the tool
# discovers us. The appliance is the single source of truth for "current mode";
# the MCP READS it and follows (stays stateless about mode).
#
# Off unless `services.pikvm.kvmd.hidMode.endpoint.enable` (default: on when both
# the hidMode apparatus and the built-in MCP are enabled).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hidModeCfg = config.services.pikvm.kvmd.hidMode;
  cfg = hidModeCfg.endpoint;

  # Runtime paths (never in the store): the shared token the endpoint reads, and
  # an EnvironmentFile that injects it into pikvm-mcp's env.
  tokenPath = "/run/pikvm-hidmode/token";
  mcpEnvPath = "/run/pikvm-hidmode/mcp.env";

  endpoint = pkgs.writeText "pikvm-hidmode-endpoint.py" ''
    import hmac, json, os, subprocess
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    PORT = int(os.environ["PORT"])
    MODES = {"desktop", "ipad"}
    MARKER = "/var/lib/kvmd/hidmode"
    with open(os.environ["TOKEN_FILE"], "r") as fh:
        TOKEN = fh.read().strip()

    def current_mode():
        # The marker is the authoritative current-mode (kvmd's /api/hid can't
        # represent single/ipad cleanly). Unseeded → the faithful default.
        try:
            with open(MARKER, "r") as fh:
                mode = fh.read().strip()
        except FileNotFoundError:
            return "desktop"
        return mode if mode in MODES else "desktop"

    class Handler(BaseHTTPRequestHandler):
        def _send_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def reply(self, code, ok, message):
            self._send_json(code, {"ok": ok, "message": message})

        def _authorized(self):
            auth = self.headers.get("Authorization", "")
            token = auth[7:] if auth.startswith("Bearer ") else ""
            return bool(token) and hmac.compare_digest(token, TOKEN)

        def do_GET(self):
            # Read-only current-mode ground truth for the MCP to follow.
            if self.path.rstrip("/") != "/hidmode":
                return self.reply(404, False, "not found")
            if not self._authorized():
                return self.reply(401, False, "unauthorized")
            return self._send_json(200, {"ok": True, "mode": current_mode()})

        def do_POST(self):
            if self.path.rstrip("/") != "/hidmode":
                return self.reply(404, False, "not found")
            if not self._authorized():
                return self.reply(401, False, "unauthorized")
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
                payload = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                return self.reply(400, False, "invalid JSON body")
            mode = payload.get("mode", "")
            if mode not in MODES:
                return self.reply(400, False, "unknown mode (want desktop|ipad)")
            if mode == current_mode():
                return self._send_json(200, {"ok": True, "mode": mode, "message": "already in %s" % mode})
            unit = "pikvm-hidmode@%s.service" % mode
            # --no-block: non-locking. The switch proceeds async (the gadget
            # re-assembles, USB re-enumerates, kvmd restarts). The client polls
            # GET /hidmode for the new mode rather than us holding the request.
            result = subprocess.run(["systemctl", "start", "--no-block", unit])
            if result.returncode == 0:
                return self._send_json(200, {
                    "ok": True, "mode": mode,
                    "message": "mode switching to %s; USB re-enumerates and the active session drops (~5s)" % mode,
                })
            return self.reply(502, False, "switch to %s failed (rc=%d)" % (mode, result.returncode))

        def log_message(self, *args):
            pass  # don't log tokens/paths

    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  options.services.pikvm.kvmd.hidMode.endpoint = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # On when both the hidMode apparatus AND the built-in MCP are enabled —
      # the endpoint is only useful if there's a switch to trigger and an MCP to
      # trigger it. Mirrors the hid-recovery endpoint's MCP-tied default.
      default = hidModeCfg.enable && (config.services.pikvm-mcp.enable or false);
      defaultText = lib.literalExpression "config.services.pikvm.kvmd.hidMode.enable && config.services.pikvm-mcp.enable";
      example = true;
      description = ''
        The authenticated loopback HID-mode endpoint (GET /hidmode reads the
        current mode; POST /hidmode {"mode": …} switches it). Enabling it also
        wires PIKVM_HIDMODE_URL + a bearer token into the pikvm-mcp service env.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8083;
      description = "Loopback port the endpoint listens on (GET/POST /hidmode).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/pikvm-hidmode-token";
      description = ''
        Bearer token shared between this endpoint and the MCP server. When null
        (default) a random token is generated at first boot. Point at a
        sops/agenix secret to manage it yourself.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = hidModeCfg.enable;
          message = "services.pikvm.kvmd.hidMode.endpoint.enable requires services.pikvm.kvmd.hidMode.enable (the endpoint triggers the pikvm-hidmode@ units it provides).";
        }
      ];

      # The endpoint's dedicated user = hidMode.triggerUser (the polkit rule in
      # hidmode.nix grants THIS user start-only on the pikvm-hidmode@ units).
      users.users.${hidModeCfg.triggerUser} = {
        isSystemUser = true;
        group = hidModeCfg.triggerUser;
        description = "PiKVM HID-mode loopback endpoint";
      };
      users.groups.${hidModeCfg.triggerUser} = { };

      # Provision the shared token (unless supplied) + the pikvm-mcp env file.
      systemd.services.pikvm-hidmode-token = {
        description = "Provision the PiKVM HID-mode bearer token";
        wantedBy = [ "multi-user.target" ];
        before = [
          "pikvm-hidmode-endpoint.service"
          "pikvm-mcp.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.coreutils ];
        script = ''
          mkdir -p /run/pikvm-hidmode
          ${
            if cfg.tokenFile != null then
              ''install -m0640 -g ${hidModeCfg.triggerUser} ${cfg.tokenFile} ${tokenPath}''
            else
              ''
                if [ ! -s ${tokenPath} ]; then
                  ( umask 027; head -c 32 /dev/urandom | base64 | tr -d '\n' > ${tokenPath} )
                  chgrp ${hidModeCfg.triggerUser} ${tokenPath}
                  chmod 0640 ${tokenPath}
                fi
              ''
          }
          ( umask 077; printf 'PIKVM_HIDMODE_TOKEN=%s\n' "$(cat ${tokenPath})" > ${mcpEnvPath} )
        '';
      };

      systemd.services.pikvm-hidmode-endpoint = {
        description = "PiKVM HID-mode loopback endpoint";
        wantedBy = [ "multi-user.target" ];
        after = [
          "pikvm-hidmode-token.service"
          "network.target"
        ];
        requires = [ "pikvm-hidmode-token.service" ];
        path = [ pkgs.systemd ]; # systemctl
        serviceConfig = {
          User = hidModeCfg.triggerUser;
          Group = hidModeCfg.triggerUser;
          Environment = [
            "PORT=${toString cfg.port}"
            "TOKEN_FILE=${tokenPath}"
          ];
          ExecStart = "${pkgs.python3}/bin/python3 ${endpoint}";
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
        };
      };

      networking.firewall = { }; # loopback only; nothing to open
    }

    # Point the MCP server at us — static URL as an env var; the secret token via
    # the runtime EnvironmentFile. Only when pikvm-mcp is actually present.
    (lib.mkIf (config.services.pikvm-mcp.enable or false) {
      services.pikvm-mcp.extraEnv.PIKVM_HIDMODE_URL =
        "http://127.0.0.1:${toString cfg.port}/hidmode";

      systemd.services.pikvm-mcp = {
        after = [ "pikvm-hidmode-token.service" ];
        wants = [ "pikvm-hidmode-token.service" ];
        # LIST form (not a bare string): systemd unitOptions concatenate list
        # definitions across modules, so this coexists with the hid-recovery
        # endpoint's own EnvironmentFile on pikvm-mcp. A bare string collides
        # (both are single-valued defs of the same option) — the appliance
        # enables BOTH endpoints, so a string here fails eval on the real host.
        serviceConfig.EnvironmentFile = [ mcpEnvPath ];
      };
    })
  ]);
}
