# mkLoopbackEndpoint — the shared shape of every PiKVM authenticated
# loopback endpoint: a dedicated user, a token-provisioning oneshot, and a
# hardened systemd unit running a small stdlib-only Python HTTP server.
# Consolidates ~160 byte-identical lines that were independently duplicated
# between hidmode-endpoint.nix (343 lines) and hid-recovery-endpoint.nix
# (300 lines) — including the security-critical constant-time bearer
# comparison (hmac.compare_digest), which existed in TWO places, silently
# driftable on one side only. See modules/lib/loopback-endpoint-handler.py
# for the shared Python half.
{
  lib,
  config,
  pkgs,
}:
{
  # Short feature label, e.g. "PiKVM HID-mode", "PiKVM HID-recovery" — used
  # to derive the token-provisioning unit's description ("Provision the
  # ${description} bearer token") and the endpoint unit's + dedicated
  # user's description ("${description} loopback endpoint").
  description,
  # Unit-name / script-filename stem, e.g. "hidmode", "hid-recovery" — units
  # are pikvm-${name}-token / pikvm-${name}-endpoint, script is
  # pikvm-${name}-endpoint.py.
  name,
  # The dedicated system user (and same-named group) this endpoint runs as.
  # The CALLER is responsible for the polkit grant to this user (typically
  # via unit-prefix-grant.nix) — this function only creates the account.
  user,
  # Loopback port the endpoint listens on.
  port,
  # Caller's `tokenFile` option value (nullable path) — a pre-supplied
  # token, or null to auto-generate one at first boot.
  tokenFile,
  # The runtime-paths.nix channel for the shared bearer token file.
  tokenChannel,
  # The runtime-paths.nix channel for the pikvm-mcp EnvironmentFile this
  # endpoint contributes its token into.
  mcpEnvChannel,
  # The env-var NAME written into mcpEnvChannel, e.g. "PIKVM_HIDMODE_TOKEN".
  mcpEnvVar,
  # Raw Python TEXT (the caller's own builtins.readFile of its
  # <feature>-routes.py) providing the route-specific Handler methods
  # (do_GET/do_POST/...) — appended after the shared handler's imports/
  # PORT/TOKEN-read/class-open/shared-methods, so this continues the SAME
  # class body at the same 4-space indent.
  handler,
  # Optional raw Python TEXT inserted BEFORE the shared handler (module-
  # level constants/helper functions this endpoint's routes need — e.g.
  # hidmode's MODES/OVERRIDE/GADGET/*_SHAS/requested_mode/observed_mode, or
  # hid-recovery's ACTIONS/UDC_ROOT/LATCH_STATUS_PATH). Safe to place before
  # the shared imports/class: nothing here is USED until a request actually
  # arrives, long after all module-level code has run.
  handlerEnv ? "",
}:
let
  tokenUnit = "pikvm-${name}-token";
  endpointUnit = "pikvm-${name}-endpoint";

  script = pkgs.writeText "${endpointUnit}.py" (
    handlerEnv
    + builtins.readFile ./loopback-endpoint-handler.py
    + handler
    + ''

      ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    ''
  );
in
lib.mkMerge [
  {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "${description} loopback endpoint";
    };
    users.groups.${user} = { };

    # Provision the shared token (unless supplied) + the pikvm-mcp env file.
    systemd.services.${tokenUnit} = {
      description = "Provision the ${description} bearer token";
      wantedBy = [ "multi-user.target" ];
      before = [
        "${endpointUnit}.service"
        "pikvm-mcp.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${builtins.dirOf tokenChannel.path}
        ${
          if tokenFile != null then
            ''install -m0640 -g ${user} ${tokenFile} ${tokenChannel.path}''
          else
            ''
              if [ ! -s ${tokenChannel.path} ]; then
                ( umask 027; head -c 32 /dev/urandom | base64 | tr -d '\n' > ${tokenChannel.path} )
                chgrp ${user} ${tokenChannel.path}
                chmod 0640 ${tokenChannel.path}
              fi
            ''
        }
        ( umask 077; printf '${mcpEnvVar}=%s\n' "$(cat ${tokenChannel.path})" > ${mcpEnvChannel.path} )
      '';
    };

    systemd.services.${endpointUnit} = {
      description = "${description} loopback endpoint";
      wantedBy = [ "multi-user.target" ];
      after = [
        "${tokenUnit}.service"
        "network.target"
      ];
      requires = [ "${tokenUnit}.service" ];
      path = [ pkgs.systemd ]; # systemctl
      serviceConfig = {
        User = user;
        Group = user;
        Environment = [
          "PORT=${toString port}"
          "TOKEN_FILE=${tokenChannel.path}"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 ${script}";
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
  (lib.mkIf config.services.pikvm.mcp.enabled {
    systemd.services.pikvm-mcp = {
      after = [ "${tokenUnit}.service" ];
      wants = [ "${tokenUnit}.service" ];
      # LIST form (not a bare string): systemd unitOptions concatenate list
      # definitions across modules, so this coexists with the OTHER
      # MCP-facing endpoint's own EnvironmentFile. A bare string collides
      # (both are single-valued defs of the same option) — the appliance
      # enables both endpoints, so a string here fails eval on the real host.
      serviceConfig.EnvironmentFile = [ mcpEnvChannel.path ];
    };
  })
]
