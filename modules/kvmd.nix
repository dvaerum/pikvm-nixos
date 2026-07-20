# kvmd — the main PiKVM daemon, wired up the NixOS way.
#
# Design notes (see the upstream Arch packaging this replaces):
#   * kvmd loads a *main config* (`--main-config`) plus `/etc/kvmd/override.yaml`
#     and everything in `/etc/kvmd/override.d/`. We generate the main config
#     from the selected platform profile and rewrite the one Arch-ism in it
#     (`/usr/bin/ustreamer`) to the Nix store path.
#   * The remaining hardcoded `/usr/...` defaults baked into kvmd's schema
#     (keymaps, extras, the platform id file, vcgencmd) are corrected through a
#     store-provided override in `override.d/`, so upstream configs stay pristine.
#   * `services.pikvm.kvmd.settings` is a declarative freeform override for the
#     user — the idiomatic replacement for hand-editing /etc/kvmd/override.yaml.
#
# Scope of THIS module: the kvmd + kvmd-media daemons, users/groups, runtime
# dirs, and config wiring. The nginx web entrypoint, OTG networking and Janus
# WebRTC are separate modules layered on top.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.kvmd;

  kvmd = cfg.package;
  ustreamer = cfg.ustreamer;

  configsDefault = "${kvmd}/share/kvmd/configs.default";

  # "v2-hdmi-rpi4" -> base=v2, video=hdmi, board=rpi4
  parts = lib.splitString "-" cfg.platform;
  platformBase = lib.elemAt parts 0;
  platformVideo = lib.elemAt parts 1;
  platformBoard = lib.elemAt parts 2;

  # The platform profile is the app's main config, with the ustreamer path
  # rewritten from the Arch location to our derivation.
  mainConfig = pkgs.runCommandLocal "kvmd-main-${cfg.platform}.yaml" { } ''
    substitute ${configsDefault}/kvmd/main/${cfg.platform}.yaml "$out" \
      --replace-quiet /usr/bin/ustreamer ${lib.getExe ustreamer}
  '';

  # Replacement for Arch's /usr/lib/kvmd/platform id file.
  platformFile = pkgs.writeText "kvmd-platform" ''
    PIKVM_MODEL=${platformBase}
    PIKVM_VIDEO=${platformVideo}
    PIKVM_BOARD=${platformBoard}
  '';

  # Corrections for the /usr paths baked into kvmd's schema defaults. YAML is a
  # superset of JSON, so toJSON is a valid override document.
  nixosPaths = pkgs.writeText "00-nixos-paths.yaml" (
    builtins.toJSON {
      kvmd = {
        info = {
          extras = "${kvmd}/share/kvmd/extras";
          hw = {
            platform = "${platformFile}";
            vcgencmd_cmd = [ (lib.getExe' pkgs.libraspberrypi "vcgencmd") ];
          };
        };
        hid.keymap = "${kvmd}/share/kvmd/keymaps/en-us";
      };
    }
  );

  userSettings = pkgs.writeText "10-settings.yaml" (builtins.toJSON cfg.settings);

  # Tools kvmd shells out to at runtime, placed on the services' PATH.
  runtimePath = [
    ustreamer
    kvmd
    pkgs.libraspberrypi
    pkgs.coreutils
    pkgs.util-linux
    pkgs.procps
    pkgs.iproute2
    pkgs.iptables
    pkgs.dnsmasq
    pkgs.sudo
    pkgs.openssl
    pkgs.v4l-utils
    pkgs.e2fsprogs
    pkgs.dosfstools
    pkgs.zstd
    config.systemd.package
  ];

  # kvmd's system users/groups (from upstream sysusers.conf). Cross-memberships
  # give e.g. kvmd-nginx read access to kvmd's unix sockets.
  kvmdGroups = [
    "kvmd"
    "kvmd-selfauth"
    "kvmd-media"
    "kvmd-pst"
    "kvmd-nbd"
    "kvmd-ipmi"
    "kvmd-vnc"
    "kvmd-localhid"
    "kvmd-nginx"
    "kvmd-janus"
    "kvmd-certbot"
    "kvmd-oled"
  ];
  kvmdUserExtraGroups = {
    kvmd = [
      "video"
      "dialout" # uucp (serial) on NixOS
      "kvmd-media"
      "kvmd-pst"
      "kvmd-nbd"
      "gpio"
      "spi"
      "systemd-journal"
    ];
    kvmd-media = [ "kvmd" ];
    kvmd-pst = [ "kvmd" ];
    kvmd-nbd = [ "kvmd" ];
    kvmd-ipmi = [ "kvmd" "kvmd-selfauth" ];
    kvmd-vnc = [ "kvmd" "kvmd-selfauth" "kvmd-certbot" ];
    kvmd-localhid = [ "input" "kvmd" "kvmd-selfauth" ];
    kvmd-nginx = [ "kvmd" "kvmd-media" "kvmd-janus" "kvmd-certbot" ];
    kvmd-janus = [ "kvmd" "audio" ];
    kvmd-certbot = [ "kvmd-pst" ];
    kvmd-oled = [ "kvmd" "kvmd-selfauth" "i2c" ];
  };
  # Users to actually create (everything in kvmdGroups except the group-only
  # kvmd-selfauth).
  kvmdUsers = lib.subtractLists [ "kvmd-selfauth" ] kvmdGroups;

  commonArgs = "--main-config ${mainConfig} "
    + "--override-config /etc/kvmd/override.yaml "
    + "--override-dir /etc/kvmd/override.d";
in
{
  options.services.pikvm.kvmd = {
    enable = lib.mkEnableOption "the PiKVM kvmd daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pikvm.kvmd;
      defaultText = lib.literalExpression "pkgs.pikvm.kvmd";
      description = "The kvmd package to run.";
    };

    ustreamer = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pikvm.ustreamer;
      defaultText = lib.literalExpression "pkgs.pikvm.ustreamer";
      description = "The ustreamer package kvmd invokes for video capture.";
    };

    platform = lib.mkOption {
      type = lib.types.str;
      example = "v2-hdmi-rpi4";
      description = ''
        PiKVM platform profile, `<base>-<video>-<board>` — selects the main
        config and (via the platform module) the device-tree/boot settings.
        Must match a profile shipped in the kvmd package
        (share/kvmd/configs.default/kvmd/main/<platform>.yaml).
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''{ kvmd.streamer.desired_fps.default = 30; }'';
      description = ''
        Declarative kvmd override, merged after the platform config. Replaces
        hand-editing /etc/kvmd/override.yaml. Follows the upstream config tree.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Users & groups ---------------------------------------------------
    users.groups = lib.genAttrs (kvmdGroups ++ [ "gpio" "spi" ]) (_: { });

    users.users = lib.genAttrs kvmdUsers (name: {
      isSystemUser = true;
      group = name;
      extraGroups = kvmdUserExtraGroups.${name} or [ ];
      description = "PiKVM ${name}";
    });

    # --- Runtime dirs & seeded mutable state ------------------------------
    systemd.tmpfiles.rules = [
      "d /run/kvmd 0775 kvmd kvmd -"
      "d /tmp/kvmd 0775 kvmd kvmd -"
      "d /var/lib/kvmd 0755 kvmd kvmd -"
      "d /var/lib/kvmd/msd 0775 kvmd kvmd -"
      "d /var/lib/kvmd/pst 1775 kvmd-pst kvmd-pst -"
      # Seed credential files once (kvmd-htpasswd/-totp then manage them).
      "C+ /etc/kvmd/htpasswd 0600 kvmd kvmd - ${configsDefault}/kvmd/htpasswd"
      "C+ /etc/kvmd/ipmipasswd 0600 kvmd-ipmi kvmd-ipmi - ${configsDefault}/kvmd/ipmipasswd"
      "C+ /etc/kvmd/vncpasswd 0600 kvmd-vnc kvmd-vnc - ${configsDefault}/kvmd/vncpasswd"
      "C+ /etc/kvmd/totp.secret 0600 kvmd kvmd - ${configsDefault}/kvmd/totp.secret"
    ];

    # --- /etc/kvmd (declarative) ------------------------------------------
    environment.etc = {
      "kvmd/meta.yaml".source = "${configsDefault}/kvmd/meta.yaml";
      "kvmd/web.css".source = "${configsDefault}/kvmd/web.css";
      # User override starts empty; real config goes through `settings`.
      "kvmd/override.yaml".text = "";
      "kvmd/override.d/00-nixos-paths.yaml".source = nixosPaths;
      "kvmd/override.d/10-settings.yaml".source = userSettings;
    };

    # --- Services ---------------------------------------------------------
    systemd.services.kvmd = {
      description = "PiKVM - The main daemon";
      after = [
        "network.target"
        "network-online.target"
        "nss-lookup.target"
      ]
      ++ lib.optional config.services.pikvm.otg.enable "kvmd-otg.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = runtimePath;
      serviceConfig = {
        User = "kvmd";
        Group = "kvmd";
        Type = "simple";
        Restart = "always";
        RestartSec = 3;
        AmbientCapabilities = "CAP_NET_RAW";
        ExecStart = "${lib.getExe kvmd} --run ${commonArgs}";
        TimeoutStopSec = 10;
        KillMode = "mixed";
      };
    };

    systemd.services.kvmd-media = {
      description = "PiKVM - Media proxy server";
      after = [ "kvmd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = runtimePath;
      serviceConfig = {
        User = "kvmd-media";
        Group = "kvmd-media";
        Type = "simple";
        Restart = "always";
        RestartSec = 3;
        ExecStart = "${kvmd}/bin/kvmd-media --run ${commonArgs}";
        TimeoutStopSec = 3;
      };
    };
  };
}
