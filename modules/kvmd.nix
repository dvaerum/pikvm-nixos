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

  # The kvmd package the module runs (also referenced for share/, the helper
  # binaries, and passthru.tesseract). iPad HID support is the RUNTIME
  # services.pikvm.kvmd.hidMode switch (modules/hidmode.nix) — a config-only
  # mode, no package patch (the old ipadCompat mouse.py patch was dead code).
  kvmd = cfg.package;

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

  # A fixed CSI (tc358743) platform, known at eval time. `&&` short-circuits
  # before the `elemAt parts 1` that would otherwise be out-of-bounds on
  # "auto" (a length-1 split) — same laziness the `platformFile` reference
  # above already relies on.
  isCsiFixed = !isAuto && (lib.elemAt parts 1) == "hdmi";
  # The per-base default EDID preset (kvmd ships v0/v1/v2/v3/v4mini/v4plus.hex
  # under configs.default/kvmd/edid/) — only forced when isCsiFixed.
  csiEdidPreset = "${configsDefault}/kvmd/edid/${lib.elemAt parts 0}.hex";

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

      # CSI/tc358743 needs its EDID loaded onto the bridge chip before kvmd's
      # streamer can ever get a signal (see the kvmd-tc358743 unit, which
      # loads this file at every boot and gates itself on it existing). The
      # right preset is per-base (v2/v3/v4mini/v4plus), which only this
      # runtime detector knows for `platform = "auto"`. Seed once — never
      # clobber an admin's own `kvmd-edidconf --set-* --apply` customisation
      # on a later boot.
      if [ "$video" = hdmi ] && [ ! -e /etc/kvmd/tc358743-edid.hex ]; then
        install -D -m 0644 "${configsDefault}/kvmd/edid/$base.hex" /etc/kvmd/tc358743-edid.hex
        echo "kvmd-platform-detect: seeded tc358743-edid.hex from $base preset" >&2
      fi
    '';
  };

  # Corrections for the absolute Arch paths baked into kvmd's schema defaults
  # (kvmd/apps/_scheme.py). YAML is a superset of JSON, so toJSON is a valid
  # override document. This override must stay COMPLETE against the scheme for
  # the apps we actually run — a missed path is a latent FileNotFoundError that
  # only surfaces when that code path first executes (ocr.tessdata killed the
  # daemon on every KVM-page open). Full audit of every absolute path default in
  # _scheme.py, and where each is handled:
  #
  #   REWRITTEN here (read by a RUNNING app — kvmd / kvmd-media / kvmd-otg):
  #     info.extras, info.hw.platform, info.hw.vcgencmd_cmd, hid.keymap;
  #     ocr.tessdata (else the OCR poller crash-loops kvmd, see below);
  #     streamer.pre_start_cmd / post_stop_cmd (default /bin/true, absent on
  #     NixOS — /bin has only `sh`; streamer.cmd itself is the ustreamer store
  #     path set by the platform profile, see mainConfigs).
  #
  #   HANDLED ELSEWHERE (not an Arch-package path we must rewrite):
  #     streamer.cmd → platform main.yaml (mainConfigs); info.meta,
  #     auth totp/ipmi/vnc password + edid files → materialised under /etc/kvmd.
  #
  #   INERT — the owning app is NEVER started (we define no kvmd-otgnet /
  #   kvmd-ipmi / kvmd-vnc / kvmd-janus service), so these defaults are never
  #   read: otgnet.{ip,iptables,sysctl,dnsmasq,systemd_run,systemctl}_cmd +
  #   otgnet pre/post hooks (_scheme.py 637–671), janus bin (795), ipmi keymap
  #   (713), gpio switch default_edid (458).
  #
  #   LATENT — real feature path, but needs more than a path rewrite (a sudoers
  #   rule for the kvmd user + the setuid sudo wrapper), tracked separately:
  #     msd/pst remount_cmd (503) = sudo + kvmd-helper-pst-remount. Only fires
  #     on an MSD read-write remount; harmless until MSD image write is used.
  nixosPaths = pkgs.writeText "00-nixos-paths.yaml" (
    builtins.toJSON {
      kvmd = {
        info = {
          # Advertise only the extras whose backing daemon we actually run.
          # kvmd's stock extras are ipmi + vnc, whose daemons (kvmd-ipmi /
          # kvmd-vnc) we don't package — pointing info.extras at kvmd's raw dir
          # would advertise them in /api/info and make the dashboard query dead
          # services (DBusError). kvmd-extras filters those out (empty today).
          # When the web Terminal is on, webterm.nix overrides this with the
          # composed extrasDir (kvmd-extras ∪ webterm) via 10-settings.
          extras = "${pkgs.pikvm.kvmd-extras}";
          hw = {
            platform = platformIdPath;
            vcgencmd_cmd = [ (lib.getExe' pkgs.libraspberrypi "vcgencmd") ];
          };
        };
        hid.keymap = "${kvmd}/share/kvmd/keymaps/en-us";
        # kvmd's OCR data_dir defaults to the Arch path /usr/share/tessdata,
        # absent on NixOS. get_available_langs() os.listdir()s it whenever OCR
        # state is enumerated (every KVM-page open, via the stream poller) →
        # FileNotFoundError kills the OCR "deadly task" and thus the whole
        # daemon (surfaces to the user as "Unexpected logout"). Point it at the
        # tessdata shipped by the exact tesseract kvmd links (eng+osd — see
        # pkgs/kvmd; kvmd's ocr.langs default is eng).
        ocr.tessdata = "${kvmd.tesseract}/share/tessdata";
        # The streamer's optional start/stop hooks default to /bin/true (Arch);
        # on NixOS /bin has only `sh`, so every stream start/stop hits a
        # FileNotFoundError. Preserve the no-op semantics with a real `true`.
        streamer = {
          pre_start_cmd = [ (lib.getExe' pkgs.coreutils "true") "pre-start" ];
          post_stop_cmd = [ (lib.getExe' pkgs.coreutils "true") "post-stop" ];
        };
        # kvmd's MSD/PST read-write remount runs `sudo … kvmd-helper-*-remount`
        # to remount the virtual-drive storage RW/RO, defaulting to the Arch
        # absolutes /usr/bin/sudo + /usr/bin/kvmd-helper-*-remount — neither of
        # which exists on NixOS, so a RW remount would fail. Point both at the
        # NixOS setuid sudo wrapper + the helper kvmd actually ships; the matching
        # least-privilege sudoers rules (mirroring stock's os/sudoers) are granted
        # in the config below. msd.remount_cmd is the LIVE MSD-RW path (run by the
        # kvmd user); pst.remount_cmd is currently inert (we run no kvmd-pst
        # service) but rewritten for faithfulness. (The helper's own hardcoded
        # /bin/mount is fixed in pkgs/kvmd.) The actual remount also needs an
        # fstab-marked MSD partition + a cabled target — HW-verified separately.
        msd.remount_cmd = [
          "/run/wrappers/bin/sudo"
          "--non-interactive"
          "${kvmd}/bin/kvmd-helper-otgmsd-remount"
          "{mode}"
        ];
        pst.remount_cmd = [
          "/run/wrappers/bin/sudo"
          "--non-interactive"
          "${kvmd}/bin/kvmd-helper-pst-remount"
          "{mode}"
        ];
      };
    }
  );

  userSettings = pkgs.writeText "10-settings.yaml" (builtins.toJSON cfg.settings);

  # The declarative config the kvmd daemons parse at startup. kvmd re-reads
  # config ONLY at startup (no SIGHUP/reload handler), so these must drive the
  # units' restartTriggers — otherwise a config-only change (e.g.
  # services.pikvm.kvmd.settings) rewrites these store files but leaves the
  # units unchanged (same kvmd package), so `nixos-rebuild switch` never
  # restarts kvmd and the change is silently inert until the next reboot or
  # package bump. NB: a restart drops active kvmd sessions — the accepted
  # tradeoff (a visible reconnect) vs a config change silently not applying.
  # NB: the mutable /var HID-mode override (override.d/90-hidmode.yaml, see
  # modules/hidmode.nix) is deliberately NOT a trigger — a mode switch restarts
  # kvmd itself, and nixos-rebuild must never reset the persisted runtime choice.
  kvmdConfigTriggers = [
    nixosPaths
    userSettings
    mainConfigs
  ];

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
  # otg.nix: this module reads config.services.pikvm.otg.enable (below) — see
  # module-list.nix / Round-2 Phase 2 for why every module now imports its own
  # declarers directly instead of relying on the aggregate to supply them.
  imports = [ ./otg.nix ];

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

    # --- MSD/PST remount privilege (mirrors stock PiKVM's os/sudoers) ------
    # kvmd runs `sudo … kvmd-helper-*-remount rw|ro` to flip the virtual-drive
    # storage read-write for image writes. Grant EXACTLY that — the kvmd user may
    # run ONLY the otgmsd-remount helper, kvmd-pst ONLY the pst-remount helper —
    # passwordless (the remount is unattended), as root, and nothing else. Stock:
    #   kvmd     ALL=(ALL) NOPASSWD: /usr/bin/kvmd-helper-otgmsd-remount
    #   kvmd-pst ALL=(ALL) NOPASSWD: /usr/bin/kvmd-helper-pst-remount
    # The remount_cmd paths (00-nixos-paths above) point at these same helpers +
    # the setuid sudo wrapper. kvmd-pst's rule is inert today (we run no kvmd-pst
    # service) but kept for faithfulness.
    security.sudo.extraRules = [
      {
        users = [ "kvmd" ];
        runAs = "ALL";
        commands = [
          {
            command = "${kvmd}/bin/kvmd-helper-otgmsd-remount";
            options = [ "NOPASSWD" ];
          }
        ];
      }
      {
        users = [ "kvmd-pst" ];
        runAs = "ALL";
        commands = [
          {
            command = "${kvmd}/bin/kvmd-helper-pst-remount";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

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
    ++ lib.optional isCsiFixed
      # For "auto" the runtime detector seeds this instead (only it knows the
      # base at boot); for a fixed CSI platform the base is already known
      # here. Same "seed once, never clobber an admin's kvmd-edidconf
      # customisation" contract as the credential C+ rules above.
      "C+ /etc/kvmd/tc358743-edid.hex 0644 kvmd kvmd - ${csiEdidPreset}"
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
    };

    # The main config captures from /dev/kvmd-video; give the capture device a
    # stable name whether it's a TC358743 (CSI) or a USB (UVC) grabber. Unlike
    # upstream's port-locked udev helper, we match the device by identity, so
    # the MacroSilicon MS2109 grabber works in any USB port.
    #
    # CSI: TWO rules, not one. `ATTR{name}=="tc358743"` is upstream's own match
    # (stock Arch's older camera stack reports the video4linux node under the
    # sensor driver's own name) and stays first for anyone it still matches.
    # But on this vendor kernel's bcm2835-unicam legacy driver, the sensor
    # (tc358743) is exposed only as a v4l-subdev — the actual /dev/videoN
    # capture NODE is unicam's own, always named "unicam-image" regardless of
    # which downstream sensor is attached. A CSI Pi 4 appliance running that
    # driver therefore never matches the first rule at all → no /dev/kvmd-video
    # → ustreamer has nothing to open → every stream is ustreamer's own
    # "NO LIVE VIDEO" placeholder JPEG, HTTP 200 and all (see the second trap
    # below — a 200 here is NOT evidence capture is working). Found in
    # production on pikvm01 (georgs-mac-mini's iPad node) 2026-08-23: real
    # /sys/class/video4linux/video0/name was "unicam-image", parented at
    # `fe801000.csi` — the SoC's fixed CSI1 controller address (PiKVM's V2/V3/V4
    # CSI HATs wire the sensor there consistently, so this is a stable match,
    # not a board-instance quirk). KERNELS scopes it to that controller so a
    # second, unrelated CSI camera some day wouldn't also match "unicam-image".
    services.udev.extraRules = ''
      SUBSYSTEM=="video4linux", ATTR{name}=="tc358743", SYMLINK+="kvmd-video"
      SUBSYSTEM=="video4linux", ATTR{name}=="unicam-image", KERNELS=="fe801000.csi", SYMLINK+="kvmd-video"
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

    # --- CSI (tc358743) EDID loader ----------------------------------------
    # Stock PiKVM's per-platform Arch package `systemctl enable`s this for
    # every CSI board — a step our packaging never replicated (untested until
    # a real CSI appliance, pikvm01, went into production 2026-08-23; our HW
    # gate rig is hdmiusb, which never exercises this path at all). Without
    # it the tc358743 never gets an EDID, the HDMI source sees no valid sink
    # and never locks, and kvmd's own DV-timings polling (streamer.cmd's
    # `--dv-timings`) has nothing to lock onto — ustreamer serves its "NO LIVE
    # VIDEO" placeholder JPEG forever, HTTP 200 and all. Defined whenever CSI
    # is POSSIBLE (fixed-CSI, or auto — which cannot rule it out at eval
    # time); ConditionPathExists is the runtime gate for auto, since the
    # detector (above) only seeds tc358743-edid.hex when it finds "hdmi" —
    # absent, this unit is a systemd-native no-op (Result=success), never a
    # failure, on a hdmiusb/USB-dongle box.
    systemd.services.kvmd-tc358743 = lib.mkIf (isCsiFixed || isAuto) {
      description = "PiKVM - EDID loader for TC358743";
      before = [ "kvmd.service" ];
      after = [ "dev-kvmd\\x2dvideo.device" "systemd-modules-load.service" ]
      ++ lib.optional isAuto "kvmd-platform-detect.service";
      requires = lib.optional isAuto "kvmd-platform-detect.service";
      wants = [ "dev-kvmd\\x2dvideo.device" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/etc/kvmd/tc358743-edid.hex";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "kvmd";
        Group = "kvmd";
        ExecStart =
          "${lib.getExe' pkgs.v4l-utils "v4l2-ctl"} --device=/dev/kvmd-video --set-edid=file=/etc/kvmd/tc358743-edid.hex --info-edid";
        # Mirrors stock's own unit (kvmd-tc358743.service upstream). Clearing
        # the EDID on stop is intentional — NOT a bug if you see video sever
        # for the ~8s a restart/stop-then-start takes to reload it: any future
        # deploy that restarts this unit (a switch that changes this module,
        # a manual restart) transiently drops the HDMI source's sink until
        # ExecStart re-fires. HW-confirmed on pikvm01, 2026-08-23 — a genuine
        # DV-timings lock (1920x1080@148.5MHz), not just a symlink check.
        ExecStop =
          "${lib.getExe' pkgs.v4l-utils "v4l2-ctl"} --device=/dev/kvmd-video --clear-edid";
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
      # Restart kvmd when its declarative config changes (see kvmdConfigTriggers).
      restartTriggers = kvmdConfigTriggers;
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
      # kvmd-media reads the same config; restart it on config changes too.
      restartTriggers = kvmdConfigTriggers;
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
