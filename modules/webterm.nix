# PiKVM web Terminal (kvmd-webterm / ttyd) — the faithful stock "Terminal"
# dashboard button, ported from pikvm/packages @ packages/kvmd-webterm (v0.50).
#
# Stock flow: ttyd binds a unix socket /run/kvmd/ttyd.sock and runs an
# interactive shell as the UNPRIVILEGED `kvmd-webterm` user (a member of the
# `kvmd` group — NOT root); nginx proxies /extras/webterm/ttyd → that socket,
# auth_request-gated exactly like the rest of the 443 dashboard. kvmd's
# ExtrasInfoSubmanager reads the webterm extra manifest
# (share/kvmd/extras/webterm/manifest.yaml) and checks kvmd-webterm.service to
# report `state.webterm`, which is what makes the UI's "• Term" button appear
# (web/share/js/kvm/info.js gates it on state.webterm.enabled||started).
#
# This module owns the SYSTEMD UNIT + USER + the `enable` option. The webterm
# extra files (manifest + nginx snippets + icon) are packaged in pkgs/ by
# @nixos-developer-system as a composed extras dir; the nginx include-globs +
# `kvmd.info.extras` repoint that light up the button are added once that lands
# (see the TODO block below), replicating kvmd's own nginx.conf.mako extras
# glob-include rather than hand-authoring the location.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.web.terminal;
  webEnabled = config.services.pikvm.web.enable;

  # The shell ttyd exec's, matching the stock unit's inline command (set the
  # terminal title, show the MOTD, sane TERM/umask, then the interactive shell).
  # Fully-pathed so it doesn't depend on the unit PATH.
  ttydShell = pkgs.writeShellScript "kvmd-webterm-shell" ''
    echo -ne "\033]0;PiKVM Terminal: $(${pkgs.inetutils}/bin/hostname -f) (ttyd)\007"
    ${pkgs.coreutils}/bin/cat /etc/motd 2>/dev/null || true
    export TERM=linux
    umask 0022
    exec ${pkgs.bashInteractive}/bin/bash
  '';
in
{
  options.services.pikvm.web.terminal = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        The stock PiKVM web Terminal (kvmd-webterm/ttyd) on the 443 dashboard —
        the "• Term" button, an interactive shell served over HTTPS behind the
        standard kvmd auth (admin/admin). On by default (faithful to stock
        PiKVM); requires services.pikvm.web.enable.

        SECURITY: this exposes an interactive shell as the unprivileged
        `kvmd-webterm` user (a member of the `kvmd` group — not root) on the host
        to any authenticated web user. Reaching root still needs the root
        password (su) or a sudoers rule this does not ship. Set false to omit it.
      '';
    };
  };

  config = lib.mkIf (webEnabled && cfg.enable) {
    # The kvmd-webterm user/group (upstream sysusers.conf): a member of `kvmd`
    # so it can create the socket in /run/kvmd (0775 kvmd kvmd).
    users.groups.kvmd-webterm = { };
    users.users.kvmd-webterm = {
      isSystemUser = true;
      group = "kvmd-webterm";
      extraGroups = [ "kvmd" ];
      home = "/home/kvmd-webterm";
      createHome = true;
      description = "PiKVM - Web terminal";
    };

    # nginx (user `nginx`) must reach the ttyd socket. The socket is created
    # kvmd-webterm:kvmd-webterm mode 0660 (via the unit's UMask=0117), so nginx
    # joins the kvmd-webterm group. (Stock adds kvmd-nginx to kvmd-webterm.)
    users.users.nginx.extraGroups = [ "kvmd-webterm" ];

    # Ported verbatim from kvmd-webterm.service: ttyd on the unix socket running
    # the shell as kvmd-webterm. UMask 0117 keeps the socket group-readable so
    # nginx (in the kvmd-webterm group) can proxy it.
    systemd.services.kvmd-webterm = {
      description = "PiKVM - Web terminal (ttyd)";
      after = [
        "network.target"
        "kvmd.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "kvmd-webterm";
        Group = "kvmd-webterm";
        WorkingDirectory = "/home/kvmd-webterm";
        Restart = "always";
        RestartSec = 1;
        UMask = "0117";
        ExecStart = "${pkgs.ttyd}/bin/ttyd -W --interface=/run/kvmd/ttyd.sock --port=0 ${ttydShell}";
      };
    };

    # kvmd's extras scanner is pointed at the COMPOSED extras dir (base ∪ webterm ∪
    # hidmode) by modules/nginx.nix — the front-door composition owner — so
    # ExtrasInfoSubmanager finds share/kvmd/extras/webterm/manifest.yaml and reports
    # state.webterm → the UI renders the "• Term" button. Composing it in ONE place
    # (rather than each extra setting kvmd.info.extras) avoids conflicting defs. The
    # nginx web-root + extras glob-includes that serve the icon and the
    # /extras/webterm/ ttyd location also live in modules/nginx.nix.
  };
}
