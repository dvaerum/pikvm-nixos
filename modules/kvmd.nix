# kvmd — the main PiKVM daemon, wired up the NixOS way.
#
# Design notes (see the upstream Arch packaging this replaces):
#   * kvmd loads a *main config* (`--main-config`) plus `/etc/kvmd/override.yaml`
#     and everything in `/etc/kvmd/override.d/`. We bake every platform profile
#     from the kvmd package (rewriting the one Arch-ism, `/usr/bin/ustreamer`,
#     to the Nix store path) and select one — either a fixed profile or, with
#     `platform = "auto"`, whichever a boot-time detector picks for the board
#     it finds itself on. This is what lets a single image serve every device.
#   * The remaining hardcoded `/usr/...` defaults baked into kvmd's schema
#     (keymaps, extras, the platform id file, vcgencmd) are corrected through a
#     store-provided override in `override.d/`, so upstream configs stay pristine.
#   * `services.pikvm.kvmd.settings` is a declarative freeform override for the
#     user — the idiomatic replacement for hand-editing /etc/kvmd/override.yaml.
#
# Scope of THIS module: the kvmd + kvmd-media daemons, platform selection,
# users/groups, runtime dirs, and config wiring. The nginx web entrypoint, OTG
# networking and Janus WebRTC are separate modules layered on top.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.kvmd;

  ustreamer = cfg.ustreamer;

  # iPadOS needs the absolute-mouse HID to advertise the boot mouse interface
  # (protocol=2, subclass=1) or it ignores clicks. Upstream hardcodes
  # protocol=0/subclass=0, so we patch it at BUILD time — no read-only-fs
  # dance, no re-apply-after-upgrade hook; it's simply baked into the package.
  kvmd =
    if cfg.ipadCompat.enable then
      cfg.package.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace kvmd/apps/otg/hid/mouse.py \
            --replace-fail 'protocol=0,  # None protocol' 'protocol=2,  # Mouse protocol' \
            --replace-fail 'subclass=0,  # No subclass' 'subclass=1,  # Boot interface subclass'
        '';
      })
    else
      cfg.package;

  # iPadOS compatibility overrides (the working values from the iPad setup
  # guide). Applied as an early override.d entry so the user's own `settings`
  # (10-settings) still win over it.
  ipadSettings = {
    kvmd = {
      streamer = {
        resolution = "1280x720"; # match iPad HDMI 16:9, lowest bandwidth
        desired_fps = 30; # smoother than 60 over USB 2.0
        cmd_append = [ "--buffers=1" ]; # much lower capture latency
      };
      hid = {
        mouse = {
          absolute = false; # relative mode; iPadOS treats absolute as touch
          horizontal_wheel = false;
        };
        mouse_alt.device = ""; # disable the 2nd mouse; confuses iPadOS
      };
    };
  };
  ipadOverride = pkgs.writeText "05-ipad.yaml" (builtins.toJSON ipadSettings);

  configsDefault = "${kvmd}/share/kvmd/configs.default";

  isAuto = cfg.platform == "auto";

  # Every platform profile (the app's main config), each with the ustreamer
  # path rewritten from the Arch location to our derivation. The detector (or
  # a fixed selection) picks one of these at runtime.
  mainConfigs = pkgs.runCommandLocal "kvmd-main-configs" { } ''
    mkdir -p "$out"
    for f in ${configsDefault}/kvmd/main/*.yaml; do
      substitute "$f" "$out/$(basename "$f")" \
        --replace-quiet /usr/bin/ustreamer ${lib.getExe ustreamer}
    done
  '';

  # For a fixed platform, parse "<base>-<video>-<board>" and pre-bake its id
  # file. For auto, the detector writes both at boot.
  parts = lib.splitString "-" cfg.platform;
  platformFile = pkgs.writeText "kvmd-platform" ''
    PIKVM_MODEL=${lib.elemAt parts 0}
    PIKVM_VIDEO=${lib.elemAt parts 1}
    PIKVM_BOARD=${lib.elemAt parts 2}
  '';

  mainConfigPath = if isAuto then "/run/kvmd/main.yaml" else "${mainConfigs}/${cfg.platform}.yaml";
  platformIdPath = if isAuto then "/run/kvmd/platform" else "${platformFile}";

  # Boot-time hardware detector: figure out board + capture device and point
  # kvmd at the matching profile. Heuristics; expected to be tuned on real
  # hardware. Falls back to the common Pi 4 CSI profile.
  detect = pkgs.writeShellApplication {
    name = "kvmd-platform-detect";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      configs=${mainConfigs}
      model=""
      [ -r /proc/device-tree/model ] && model=$(tr -d '\0' </proc/device-tree/model || true)

      board=rpi4
      case "$model" in
        *"Zero 2"*)            board=zero2w ;;
        *"Compute Module 4"*)  board=cm4 ;;
        *"Compute Module 5"*)  board=cm4 ;;   # best effort
        *"Pi 4"*)              board=rpi4 ;;
        *"Pi 5"*)              board=rpi4 ;;   # best effort (unsupported video)
      esac

      # Official v3/v4 HATs identify themselves via a HAT EEPROM.
      base=v2
      if [ -r /proc/device-tree/hat/product ]; then
        prod=$(tr -d '\0' </proc/device-tree/hat/product || true)
        case "$prod" in
          *v4plus*|*V4PLUS*|*"v4 plus"*) base=v4plus ;;
          *v4mini*|*V4MINI*)             base=v4mini ;;
          *v4*|*V4*)                     base=v4plus ;;
          *v3*|*V3*)                     base=v3 ;;
        esac
      fi

      # Capture device: a TC358743 (CSI) shows up as a v4l2 device by that
      # name; otherwise assume a USB (UVC) grabber.
      video=hdmiusb
      for n in /sys/class/video4linux/*/name; do
        [ -r "$n" ] || continue
        if grep -qi tc358743 "$n"; then video=hdmi; break; fi
      done

      variant="$base-$video-$board"
      if [ ! -e "$configs/$variant.yaml" ]; then
        echo "kvmd-platform-detect: no profile '$variant' (model='$model'); falling back to v2-hdmi-rpi4" >&2
        variant=v2-hdmi-rpi4
        base=v2; video=hdmi; board=rpi4
      fi

      install -d -m 0775 -o kvmd -g kvmd /run/kvmd
      ln -sf "$configs/$variant.yaml" /run/kvmd/main.yaml
      printf 'PIKVM_MODEL=%s\nPIKVM_VIDEO=%s\nPIKVM_BOARD=%s\n' "$base" "$video" "$board" >/run/kvmd/platform
      echo "kvmd-platform-detect: selected $variant" >&2
    '';
  };

  # Corrections for the /usr paths baked into kvmd's schema defaults. YAML is a
  # superset of JSON, so toJSON is a valid override document.
  nixosPaths = pkgs.writeText "00-nixos-paths.yaml" (
    builtins.toJSON {
      kvmd = {
        info = {
          extras = "${kvmd}/share/kvmd/extras";
          hw = {
            platform = platformIdPath;
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

  commonArgs = "--main-config ${mainConfigPath} "
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
      default = "auto";
      example = "v2-hdmi-rpi4";
      description = ''
        PiKVM platform profile as `<base>-<video>-<board>`, or `"auto"` (the
        default) to detect board + capture device at boot and pick the profile
        automatically — what makes one image usable on every device. A fixed
        value must match a profile shipped in the kvmd package
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

    commonArgs = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = commonArgs;
      defaultText = lib.literalMD "the computed `--main-config`/`--override-*` arguments";
      description = ''
        The main/override config CLI arguments kvmd is launched with. Exposed so
        sibling services (kvmd-otg) invoke the daemon suite against the same
        selected platform profile instead of kvmd's baked `/usr/...` defaults.
      '';
    };

    ipadCompat.enable = lib.mkEnableOption ''
      iPadOS compatibility. Bundles everything from the PiKVM-on-iPad setup
      guide declaratively: patches the absolute-mouse HID to advertise the boot
      mouse interface (protocol=2/subclass=1, so iPadOS accepts clicks), forces
      relative mouse mode, disables the secondary mouse, and applies the tuned
      USB-capture streamer settings (1280x720@30, --buffers=1). Your own
      `settings` still override these
    '';
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
    ]
    ++ lib.optional (!isAuto)
      # A fixed platform has no boot-time detector writing /run/kvmd/main.yaml,
      # so materialise it here — kvmd's --main-config default now points there
      # (see pkgs/kvmd) and kvmd-otg re-validates that path.
      "L+ /run/kvmd/main.yaml - - - - ${mainConfigs}/${cfg.platform}.yaml";

    # --- /etc/kvmd (declarative) ------------------------------------------
    environment.etc = {
      "kvmd/meta.yaml".source = "${configsDefault}/kvmd/meta.yaml";
      "kvmd/web.css".source = "${configsDefault}/kvmd/web.css";
      # User override starts empty; real config goes through `settings`.
      "kvmd/override.yaml".text = "";
      "kvmd/override.d/00-nixos-paths.yaml".source = nixosPaths;
      "kvmd/override.d/10-settings.yaml".source = userSettings;
    }
    // lib.optionalAttrs cfg.ipadCompat.enable {
      "kvmd/override.d/05-ipad.yaml".source = ipadOverride;
    };

    # The main config captures from /dev/kvmd-video; give the capture device a
    # stable name whether it's a TC358743 (CSI) or a USB (UVC) grabber. Unlike
    # upstream's port-locked udev helper, we match the device by identity, so
    # the MacroSilicon MS2109 grabber works in any USB port.
    services.udev.extraRules = ''
      SUBSYSTEM=="video4linux", ATTR{name}=="tc358743", SYMLINK+="kvmd-video"
      SUBSYSTEM=="video4linux", ATTRS{idVendor}=="534d", ATTRS{idProduct}=="2109", ATTR{index}=="0", SYMLINK+="kvmd-video"
      SUBSYSTEM=="video4linux", ENV{ID_V4L_CAPABILITIES}==":capture:", ENV{ID_USB_INTERFACES}=="*:0e02*", ATTR{index}=="0", SYMLINK+="kvmd-video"

      # OTG HID gadget devices → the names kvmd's HID plugin opens. Ships in
      # upstream's v2-hdmiusb-rpi4.rules; without these the OTG keyboard/mouse
      # silently don't work on a real Pi 4 (the gadget binds /dev/hidgN but
      # kvmd looks for /dev/kvmd-hid-*).
      KERNEL=="hidg0", GROUP="kvmd", SYMLINK+="kvmd-hid-keyboard"
      KERNEL=="hidg1", GROUP="kvmd", SYMLINK+="kvmd-hid-mouse"
      KERNEL=="hidg2", GROUP="kvmd", SYMLINK+="kvmd-hid-mouse-alt"
    '';

    # --- Platform detection (auto only) -----------------------------------
    systemd.services.kvmd-platform-detect = lib.mkIf isAuto {
      description = "PiKVM - Detect hardware platform";
      before = [
        "kvmd.service"
        "kvmd-media.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe detect;
      };
    };

    # --- Services ---------------------------------------------------------
    systemd.services.kvmd = {
      description = "PiKVM - The main daemon";
      after = [
        "network.target"
        "network-online.target"
        "nss-lookup.target"
      ]
      ++ lib.optional isAuto "kvmd-platform-detect.service"
      ++ lib.optional config.services.pikvm.otg.enable "kvmd-otg.service";
      requires = lib.optional isAuto "kvmd-platform-detect.service";
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
      after = [ "kvmd.service" ]
      ++ lib.optional isAuto "kvmd-platform-detect.service";
      requires = lib.optional isAuto "kvmd-platform-detect.service";
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
