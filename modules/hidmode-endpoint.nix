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
    GADGET = "/sys/kernel/config/usb_gadget/kvmd"
    with open(os.environ["TOKEN_FILE"], "r") as fh:
        TOKEN = fh.read().strip()

    # kvmd 4.188 mouse report_descriptor sha256s (it-03400 re-derived on 4.188).
    # Mode is classified by descriptor SHA (+ mouse count) per the #51 ruling —
    # NOT proto/subclass (the stock relative maker already reads 2/1) and NOT a
    # report_length constant. An unrecognised descriptor => observed=None => the
    # MCP fail-closes (safe). Pinned to 4.188; a kvmd bump that changes the
    # descriptor bytes makes observe() return None until these are refreshed.
    REL_SHAS = {
        "55c045b2daf5c91fd72fd8e1821e02a41c4118ea1badfdf4644e6db3d9970eed",  # relative, horizontal_wheel=false (ipad)
        "92155ddf022d4091f5e15eea5871107cd6ff7a4e6ada0ef931bd14b86c5632d0",  # relative, horizontal_wheel=true
    }
    ABS_SHAS = {
        "d9b93f5aa0cb2ab2f041d8c2da5f5b6c527e74192e2f1efa15c4844bec079621",  # absolute, horizontal_wheel=false
        "3a71a5a23705ee80a711e143d1242e34cb5d85592d4b5e6ac3f20bf8b9830a12",  # absolute, horizontal_wheel=true
    }

    def requested_mode():
        # The marker = INTENT: what pikvm-hidmode wrote + what the box assembles
        # on boot. Persistence/seed only — NOT what the endpoint reports as the
        # current mode (the marker is written BEFORE kvmd-otg reassembles, so a
        # failed/partial switch leaves it lying). Unseeded => the faithful default.
        try:
            with open(MARKER, "r") as fh:
                mode = fh.read().strip()
        except FileNotFoundError:
            return "desktop"
        return mode if mode in MODES else "desktop"

    def observed_mode():
        # The ASSEMBLED gadget is ground truth. Classify the mouse HID functions
        # LINKED into the active config (configs/*/hid.* — NOT the functions/
        # pool, which keeps removed functions readable and would report a removed
        # mouse as present) by report_descriptor sha256:
        #   ipad    = exactly one RELATIVE mouse, no absolute (single relative).
        #   desktop = one ABSOLUTE (primary) + one RELATIVE (mouse_alt) — dual.
        # Returns None when the gadget is absent / mid-reassembly / an
        # unrecognised topology => the caller reports "settling", never a stale
        # or wrong mode.
        import glob, hashlib
        if not os.path.isdir(GADGET):
            return None  # torn down mid-switch — nothing to classify
        abs_n = rel_n = 0
        for link in glob.glob(GADGET + "/configs/*/hid.*"):
            if not os.path.islink(link):
                continue
            try:
                with open(os.path.join(os.path.realpath(link), "report_desc"), "rb") as fh:
                    sha = hashlib.sha256(fh.read()).hexdigest()
            except OSError:
                continue
            if sha in ABS_SHAS:
                abs_n += 1
            elif sha in REL_SHAS:
                rel_n += 1
        if abs_n == 0 and rel_n == 1:
            return "ipad"
        if abs_n == 1 and rel_n == 1:
            return "desktop"
        return None  # 0 mice / partial / unexpected => unknown (settling)

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
            if self.path.rstrip("/") != "/hidmode":
                return self.reply(404, False, "not found")
            if not self._authorized():
                return self.reply(401, False, "unauthorized")
            requested = requested_mode()
            observed = observed_mode()
            # `mode` is the ASSEMBLED gadget (the ground truth the MCP follows),
            # NOT the marker: null while mid-reassembly/unrecognised so the MCP
            # fail-closes on its settling gate instead of driving the wrong mode.
            # `requested` (marker) + `settled` ride along: requested != observed
            # after settling = the switch didn't take (a drift signal nothing
            # detected before).
            return self._send_json(200, {
                "ok": True,
                "mode": observed,
                "requested": requested,
                "observed": observed,
                "settled": observed is not None,
            })

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
            # Skip the switch only if the ASSEMBLED gadget is already this mode —
            # comparing against observed (not the marker) so a marker/gadget
            # drift (a prior failed switch) still triggers a corrective reassembly
            # instead of being no-op'd away.
            if mode == observed_mode():
                return self._send_json(200, {"ok": True, "mode": mode, "message": "already in %s (gadget confirms)" % mode})
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
