# The dashboard HID-mode control (#51, control surface 3 of 3: API / UI / MCP) —
# the WEB half. The loopback token endpoint (modules/hidmode-endpoint.nix) is
# MCP-facing and 127.0.0.1-only; a browser cannot reach it and must never hold
# the bearer token. This module bridges that gap on the 443 front-door:
#
#   browser --(443, dashboard-authed)--> nginx  --(loopback + server-side bearer)-->  127.0.0.1:8083 /hidmode
#
# SECURITY (see docs/decisions/0002-hidmode-web-control.md):
#   - The /hidmode proxy inherits the stock server-level `auth_request
#     /auth_check`, so it sits behind the SAME dashboard auth as the rest of the
#     UI. No anonymous path to a switch that re-plugs the target's USB.
#   - The bearer token is read from a RUNTIME path (/run/pikvm-hidmode/token,
#     the endpoint's own token) into a 0640 root:nginx include and injected
#     server-side; it is NEVER in /nix/store and NEVER sent to the browser.
#   - `proxy_set_header Authorization ""` is the base (a client can't smuggle a
#     token), then the generated include sets the real bearer (last wins). If
#     the include is absent (glob matches nothing — fail-safe boot ordering),
#     the upstream gets an empty bearer -> 401, never an open switch.
#
# This is control "a" (a self-contained authenticated page at /hidmode-control).
# Integrating the toggle into the stock dashboard menu (the webterm precedent)
# is the REQUIRED faithfulness follow-up, tracked in the ADR.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  webCfg = config.services.pikvm.web;
  cfg = webCfg.hidModeControl;
  # `or { }` keeps this module composable when imported (via nginx.nix) WITHOUT the
  # hidMode stack — e.g. the webterm VM test, which pulls nginx.nix but not
  # hidmode.nix/hidmode-endpoint.nix. Then endpoint.enable is absent → the
  # hidModeControl default below resolves false and the mkIf config never forces
  # endpointCfg.port. The real appliance imports the full stack, so it's the real
  # endpoint there.
  endpointCfg = config.services.pikvm.kvmd.hidMode.endpoint or { };

  # The endpoint's own runtime token (provisioned by pikvm-hidmode-token.service
  # in hidmode-endpoint.nix). We read it, never own it — canonical contract in
  # modules/runtime-paths.nix (Finding 3, Phase 2); this was independently
  # hardcoded here AND in hidmode-endpoint.nix before, silently driftable.
  tokenPath = config.services.pikvm.runtimePaths.hidmodeToken.path;
  authDir = "/run/pikvm-hidmode-proxy";

  controlHtml = pkgs.writeText "hidmode-control.html" (builtins.readFile ./hidmode-control.html);

  # The #51 option-b landing tile links to /hidmode-control/ (index/main.js always
  # appends "/" to the extras manifest `path`). nginx can't serve a file from a
  # "/"-terminated URI two ways over (a file `alias` concatenates `index.html` onto
  # the path; `alias`+`index` internally redirects to the server root, not the
  # alias — both footguns). The idiomatic fix is to canonicalize the slash form to
  # the served no-slash page with a 301; browsers (and `curl -L`) follow it
  # transparently. So only the no-slash /hidmode-control serves the file.
  controlAuth = ''
    include /etc/kvmd/nginx/loc-login.conf;
    include /etc/kvmd/nginx/loc-nocache.conf;
  '';
in
{
  options.services.pikvm.web.hidModeControl = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # On when the web front-door AND the hidMode endpoint are both on — the
      # control is only meaningful if there's a 443 dashboard to host it and a
      # loopback endpoint to proxy to. Absent on a stock-like install with no
      # endpoint (faithful).
      default = webCfg.enable && (endpointCfg.enable or false);
      defaultText = lib.literalExpression "config.services.pikvm.web.enable && config.services.pikvm.kvmd.hidMode.endpoint.enable";
      example = false;
      description = ''
        Serve the dashboard HID-mode control on the 443 vhost: a `/hidmode`
        reverse-proxy that authenticates the browser via the SAME dashboard auth
        as the rest of the UI and injects the loopback endpoint's bearer token
        server-side (never exposing it to the browser), plus a self-contained
        control page at `/hidmode-control`. Requires
        `services.pikvm.kvmd.hidMode.endpoint.enable`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = endpointCfg.enable;
        message = "services.pikvm.web.hidModeControl.enable requires services.pikvm.kvmd.hidMode.endpoint.enable (it proxies to that loopback endpoint).";
      }
      {
        assertion = webCfg.enable;
        message = "services.pikvm.web.hidModeControl.enable requires services.pikvm.web.enable (it adds locations to the 443 vhost).";
      }
    ];

    # Generate the server-side bearer include from the endpoint's runtime token,
    # BEFORE nginx parses its config. 0640 root:nginx; token never leaves /run.
    systemd.services.pikvm-hidmode-proxy-auth = {
      description = "Generate the nginx server-side bearer include for the /hidmode proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "pikvm-hidmode-token.service" ];
      requires = [ "pikvm-hidmode-token.service" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -eu
        install -d -m0750 -o root -g nginx ${authDir}
        tok="$(cat ${tokenPath})"
        ( umask 027; printf 'proxy_set_header Authorization "Bearer %s";\n' "$tok" > ${authDir}/authheader.conf )
        chgrp nginx ${authDir}/authheader.conf
        chmod 0640 ${authDir}/authheader.conf
      '';
    };

    # nginx normally starts after the include exists; the glob include below is
    # fail-safe if it doesn't (empty bearer -> upstream 401, never an open path).
    systemd.services.nginx = {
      after = [ "pikvm-hidmode-proxy-auth.service" ];
      wants = [ "pikvm-hidmode-proxy-auth.service" ];
    };

    services.nginx.virtualHosts."pikvm".locations = {
      # The mode-switch API proxy. Inherits the stock server-level
      # `auth_request /auth_check` -> dashboard session required. Bearer injected
      # server-side; loopback upstream; browser never sees :8083 or the token.
      "= /hidmode" = {
        proxyPass = "http://127.0.0.1:${toString endpointCfg.port}";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Proto $scheme;
          # Base: never forward the client's Authorization; the include (when
          # present) sets the real bearer, last-wins.
          proxy_set_header Authorization "";
          include ${authDir}/*.conf;
        '';
      };

      # The self-contained control page (control "a"). Dashboard-authed; a
      # browser hitting it unauth gets 302->login (loc-login), like the rest of
      # the UI. The no-slash form serves the file; the trailing-slash form the
      # landing-dashboard tile (#51 option-b) links to 301-canonicalizes to it.
      "= /hidmode-control".extraConfig = ''
        ${controlAuth}default_type text/html;
        alias ${controlHtml};
      '';
      "= /hidmode-control/".extraConfig = "return 301 /hidmode-control;";
    };
  };
}
