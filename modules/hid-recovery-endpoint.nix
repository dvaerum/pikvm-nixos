# The authenticated loopback HID-recovery endpoint — the integration half of
# the HID-recovery feature. The privileged executor + the templated root units
# `pikvm-hid-recover@<action>.service` + the polkit rule live in
# `services.pikvm.hidRecovery` (modules/hid-recovery.nix, kvmd lane).
#
# Flow: the MCP server's `pikvm_hid_recover` tool POSTs {"action": ...} + a
# bearer token to this loopback endpoint; we validate the token and
# `systemctl start pikvm-hid-recover@<action>.service` (polkit grants our user
# start-only on those units — no sudo/setuid). We also wire
# PIKVM_HID_RECOVERY_URL / PIKVM_HID_RECOVERY_TOKEN into services.pikvm-mcp so
# the tool discovers us. Off unless `services.pikvm.hidRecovery.endpoint.enable`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.hidRecovery.endpoint;

  # Runtime paths (never in the store): the shared token the endpoint reads,
  # and an EnvironmentFile that injects it into pikvm-mcp's env.
  tokenPath = "/run/pikvm-hid-recovery/token";
  mcpEnvPath = "/run/pikvm-hid-recovery/mcp.env";

  # The action set is the MCP trigger contract (docs/runbooks/hid-recovery.md);
  # instance names are the action strings verbatim (mixed separators intact).
  endpoint = pkgs.writeText "pikvm-hid-recovery-endpoint.py" ''
    import hmac, json, os, subprocess
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    PORT = int(os.environ["PORT"])
    ACTIONS = {"soft_connect", "udc-rebind", "reboot"}
    UDC_ROOT = "/sys/class/udc"
    with open(os.environ["TOKEN_FILE"], "r") as fh:
        TOKEN = fh.read().strip()

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

        def do_POST(self):
            if self.path.rstrip("/") != "/hid-recovery":
                return self.reply(404, False, "not found")
            if not self._authorized():
                return self.reply(401, False, "unauthorized")
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
                payload = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                return self.reply(400, False, "invalid JSON body")
            action = payload.get("action", "")
            if action not in ACTIONS:
                return self.reply(400, False, "unknown action")
            unit = "pikvm-hid-recover@%s.service" % action
            result = subprocess.run(["systemctl", "start", unit])
            if result.returncode == 0:
                return self.reply(200, True, "%s triggered" % action)
            return self.reply(502, False, "%s failed (rc=%d)" % (action, result.returncode))

        def do_GET(self):
            # Read-only GROUND-TRUTH UDC state for the MCP health_check: the kvmd
            # HID online flags can lie, but /sys/class/udc/<udc>/state is
            # authoritative. Pure read of a world-readable (0444) sysfs node — no
            # root, no polkit, no systemctl (never touches the privileged units).
            if self.path.rstrip("/") != "/hid-recovery/udc-state":
                return self.reply(404, False, "not found")
            if not self._authorized():
                return self.reply(401, False, "unauthorized")
            try:
                udcs = sorted(os.listdir(UDC_ROOT))
            except FileNotFoundError:
                udcs = []
            if not udcs:
                # No gadget bound (UDC unregistered) — endpoint is healthy, but
                # HID is down; the null/"absent" pair is that ground-truth signal.
                return self._send_json(200, {"udc": None, "state": "absent", "online": False})
            udc = udcs[0]
            try:
                with open(os.path.join(UDC_ROOT, udc, "state")) as fh:
                    state = fh.read().strip()
            except OSError as exc:
                return self.reply(500, False, "cannot read UDC state: %s" % type(exc).__name__)
            # `online` is a derived ground-truth HID-live signal for the MCP
            # health_check (state == "configured"); the raw `state` string rides
            # along for diagnostics ("not attached" vs "addressed" vs …).
            return self._send_json(200, {"udc": udc, "state": state, "online": state == "configured"})

        def log_message(self, *args):
            pass  # don't log tokens/paths

    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  options.services.pikvm.hidRecovery.endpoint = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # DEFAULT-ON whenever the built-in MCP is enabled. The MCP's
      # pikvm_hid_recover (M0 self-recovery) and health_check UDC ground-truth
      # (M4) tools are DECORATIVE without this loopback endpoint + the
      # PIKVM_HID_RECOVERY_URL wiring below — the one tool that fixes an HID-down
      # no-ops on the box that needs it. Phase 2 made the MCP default-on but left
      # this behind; tie it to the MCP so a faithful default appliance has
      # self-recovery working out of the box. Loopback-only (no firewall port),
      # token auto-generated at first boot, polkit-least-privilege → safe to
      # default on. Stays off when the MCP is off (e.g. zero2w), where it would
      # be a pointless idle server. Set explicitly to override either way.
      default = config.services.pikvm-mcp.enable or false;
      defaultText = lib.literalExpression "config.services.pikvm-mcp.enable";
      example = true;
      description = ''
        The authenticated loopback HID-recovery endpoint that lets the MCP server
        trigger the pikvm-hid-recover@<action> units and read the ground-truth
        UDC state (POST /hid-recovery, GET /hid-recovery/udc-state). Enabling it
        also wires PIKVM_HID_RECOVERY_URL + the bearer token into the pikvm-mcp
        service env. Defaults on when services.pikvm-mcp is enabled.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Loopback port the endpoint listens on (POST /hid-recovery).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/pikvm-hid-recovery-token";
      description = ''
        Bearer token shared between this endpoint and the MCP server. When null
        (default) a random token is generated at first boot. Point at a
        sops/agenix secret to manage it yourself.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Pull in the privileged executor + units + polkit (kvmd lane), whose
      # triggerUser defaults to the user we create below.
      services.pikvm.hidRecovery.enable = true;

      users.users.pikvm-hid-recovery = {
        isSystemUser = true;
        group = "pikvm-hid-recovery";
        description = "PiKVM HID-recovery loopback endpoint";
      };
      users.groups.pikvm-hid-recovery = { };

      # Provision the shared token (unless supplied) + the pikvm-mcp env file.
      systemd.services.pikvm-hid-recovery-token = {
        description = "Provision the PiKVM HID-recovery bearer token";
        wantedBy = [ "multi-user.target" ];
        before = [
          "pikvm-hid-recovery-endpoint.service"
          "pikvm-mcp.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.coreutils ];
        script = ''
          mkdir -p /run/pikvm-hid-recovery
          ${
            if cfg.tokenFile != null then
              ''install -m0640 -g pikvm-hid-recovery ${cfg.tokenFile} ${tokenPath}''
            else
              ''
                if [ ! -s ${tokenPath} ]; then
                  ( umask 027; head -c 32 /dev/urandom | base64 | tr -d '\n' > ${tokenPath} )
                  chgrp pikvm-hid-recovery ${tokenPath}
                  chmod 0640 ${tokenPath}
                fi
              ''
          }
          # EnvironmentFile for pikvm-mcp (systemd reads it as root before
          # dropping privileges, so 0600 root keeps the token off the store and
          # out of the static unit env).
          ( umask 077; printf 'PIKVM_HID_RECOVERY_TOKEN=%s\n' "$(cat ${tokenPath})" > ${mcpEnvPath} )
        '';
      };

      systemd.services.pikvm-hid-recovery-endpoint = {
        description = "PiKVM HID-recovery loopback endpoint";
        wantedBy = [ "multi-user.target" ];
        after = [
          "pikvm-hid-recovery-token.service"
          "network.target"
        ];
        requires = [ "pikvm-hid-recovery-token.service" ];
        path = [ pkgs.systemd ]; # systemctl
        serviceConfig = {
          User = "pikvm-hid-recovery";
          Group = "pikvm-hid-recovery";
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

    # Point the MCP server at us — static URL as an env var; the secret token
    # via the runtime EnvironmentFile. Only when pikvm-mcp is actually present.
    (lib.mkIf (config.services.pikvm-mcp.enable or false) {
      services.pikvm-mcp.extraEnv.PIKVM_HID_RECOVERY_URL =
        "http://127.0.0.1:${toString cfg.port}/hid-recovery";

      systemd.services.pikvm-mcp = {
        after = [ "pikvm-hid-recovery-token.service" ];
        wants = [ "pikvm-hid-recovery-token.service" ];
        # LIST form so this concatenates with other MCP-facing endpoints'
        # EnvironmentFile (e.g. hidmode-endpoint) instead of colliding — the
        # appliance enables both, and two bare-string defs of one option fail
        # eval. systemd unitOptions merge list definitions across modules.
        serviceConfig.EnvironmentFile = [ mcpEnvPath ];
      };
    })
  ]);
}
