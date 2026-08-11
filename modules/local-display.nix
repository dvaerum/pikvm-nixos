# PiKVM local display — an OPT-IN, beyond-stock service that renders the
# captured HDMI-IN feed to one of the Pi4B's OWN micro-HDMI (DRM/KMS) outputs, so
# a monitor cabled to the Pi mirrors the target's screen (#52).
#
# It is the Pi4B-generic equivalent of PiKVM's V4-Plus HDMI passthrough
# (docs.pikvm.org/pass), which is dedicated-output hardware we don't have — but a
# Pi4B has two micro-HDMI KMS outputs, and our rpi4 host already enables
# `vc4-kms-v3d` (rendered config.txt), so /dev/dri/card* exists and those outputs
# are usable DRM targets. The old "a Pi4 has no HDMI-OUT" note was only ever about
# the V4-Plus passthrough FEATURE, not the hardware.
#
# Implementation = the cheap "Option B": a fullscreen `mpv --vo=drm` on the
# existing capture, NOT the ustreamer WITH_V4P port (Option A hardcodes the
# V4-Plus card + HDMI-A-2 with no CLI override → a carried source patch). mpv was
# measured live on real appliance silicon at 1080p30 (it-03400) and georg has seen
# the picture.
#
# `mode` governs the two micro-HDMI port roles:
#   * fixed (DEFAULT): capture pinned to `captureConnector`; the OTHER micro-HDMI
#     stays the system console (boot log + login getty). Deterministic — a box
#     always boots a usable console on a known port, capture on the other.
#   * auto: capture FOLLOWS whichever micro-HDMI is connected, re-rendering when
#     the cable moves (the hotplug supervisor). ⚠️ the exact unplug/replug/move
#     recovery is UNMEASURED on HW — needs an on-appliance characterization with
#     georg before `auto` is called proven.
#   * both: mirror to both outputs, no console — HELD (eval-errors) until georg
#     locks the semantics.
#
# ⚠️ Capture is capped at the DONGLE's 1920x1080 hardware ceiling (measured: UVC
# device, no higher mode, source timings unreadable). If the source outputs
# >1080p the dongle downscales IN HARDWARE — no module setting recovers it;
# sharpness beyond that is a source/dongle matter, out of scope here.
#
# ⚠️ HELD: opt-in (default off), NOT enabled on any host. The DRM path is proven
# (georg saw the picture); what's unconfirmed is this MODULE's own wiring (VT +
# supervisor) and the per-mode console coexistence. Deploy only on georg's
# explicit greenlight of the finished behavior.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.localDisplay;

  # Player args (mpv-shaped), WITHOUT the binary and WITHOUT --drm-connector (the
  # connector is chosen at runtime by the supervisor per `mode`).
  playerArgs = [
    "--vo=drm"
    "--no-audio"
    "--profile=low-latency"
    "--no-cache"
    "--loop=inf" # a systemd service should survive the source ending
  ]
  ++ lib.optional (cfg.drmDevice != null) "--drm-device=${cfg.drmDevice}"
  ++ (
    if cfg.source == "v4l2" then
      [
        "--untimed"
        # LOAD-BEARING: without input_format=mjpeg the dongle negotiates raw YUYV
        # over USB2 and drops to ~5 fps at 1080p (measured, it-03400). The MJPEG
        # hint is what buys 30 fps.
        "--demuxer-lavf-o=input_format=mjpeg,video_size=${cfg.captureResolution},framerate=${toString cfg.captureFramerate}"
        "av://v4l2:${cfg.device}"
      ]
    else
      [
        "--tls-verify=no" # loopback nginx streamer is self-signed
        cfg.streamUrl
      ]
  )
  ++ cfg.extraArgs;

  # Supervisor. `mode` picks the target connector:
  #   fixed → the pinned captureConnector (only while it is `connected`)
  #   auto  → the first `connected` HDMI-A output, and re-render when that changes
  # In BOTH modes it re-renders when its chosen target's connection state changes,
  # so it survives an unplug→replug (fixed) or a cable move (auto). Surgical: it
  # acts only on a real target change, not on every (benign) DRM uevent.
  runner = pkgs.writeShellApplication {
    name = "pikvm-local-display";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
    ];
    # NOT errexit — the supervisor loop must survive the player exiting and a
    # no-connector poll without dying.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = ''
      mode=${lib.escapeShellArg cfg.mode}
      fixed_connector=${lib.escapeShellArg cfg.captureConnector}

      # Is a specific connector (e.g. HDMI-A-2) currently connected?
      connector_connected() {
        local s
        for s in /sys/class/drm/card*-"$1"/status; do
          [ -e "$s" ] || continue
          [ "$(cat "$s" 2>/dev/null)" = "connected" ] && return 0
        done
        return 1
      }

      # Echo the first `connected` HDMI-A connector name (e.g. HDMI-A-1), or "".
      first_connected() {
        local status dir
        for status in /sys/class/drm/card*-HDMI-A-*/status; do
          [ -e "$status" ] || continue
          if [ "$(cat "$status" 2>/dev/null)" = "connected" ]; then
            dir=$(basename "$(dirname "$status")")   # e.g. card0-HDMI-A-1
            printf '%s' "''${dir#card*-}"            # -> HDMI-A-1
            return 0
          fi
        done
        # nothing connected: print nothing (caller treats "" as no-output)
      }

      # The connector to render on right now, per mode ("" if none available).
      pick_target() {
        if [ "$mode" = "fixed" ]; then
          if connector_connected "$fixed_connector"; then printf '%s' "$fixed_connector"; fi
        else
          first_connected
        fi
      }

      mpv_pid=""
      cleanup() { if [ -n "$mpv_pid" ]; then kill "$mpv_pid" 2>/dev/null || true; fi; }
      trap cleanup EXIT
      ${lib.optionalString (cfg.source == "v4l2") ''
        # v4l2 is single-open: while this holds the capture device the web KVM's
        # video is unavailable (first grabber wins). Say so loudly — a dark remote
        # view is otherwise a silent, confusing failure of the KVM's main job.
        echo "pikvm-local-display: source=v4l2 holds ${cfg.device} EXCLUSIVELY — the web UI video is UNAVAILABLE while this runs." >&2
      ''}
      ${lib.optionalString (cfg.source == "mjpeg") ''
        # mjpeg reads the shared stream, so the web UI keeps working. This relies
        # on mpv-as-a-persistent-client keeping kvmd's on-demand streamer up.
        # UNVERIFIED on HW — if kvmd drops the streamer despite an active client,
        # an explicit kvmd always-on config is the follow-up.
        echo "pikvm-local-display: source=mjpeg — keeping the shared stream open (streamer-always-on via a persistent client; UNVERIFIED on HW)." >&2
      ''}

      while true; do
        target="$(pick_target)"
        if [ -z "$target" ]; then
          echo "pikvm-local-display: no target output for mode=$mode; waiting for hotplug" >&2
          sleep 2
          continue
        fi
        echo "pikvm-local-display: rendering on connector $target (mode=$mode)" >&2
        ${lib.getExe cfg.package} --drm-connector="$target" ${lib.escapeShellArgs playerArgs} &
        mpv_pid=$!
        # Re-render if our target changes underneath us (move in auto, unplug in fixed).
        while kill -0 "$mpv_pid" 2>/dev/null; do
          sleep 2
          now="$(pick_target)"
          if [ "$now" != "$target" ]; then
            echo "pikvm-local-display: target changed ($target -> ''${now:-none}); re-rendering" >&2
            kill "$mpv_pid" 2>/dev/null || true
            break
          fi
        done
        wait "$mpv_pid" 2>/dev/null || true
        mpv_pid=""
        sleep 1
      done
    '';
  };
in
{
  options.services.pikvm.localDisplay = {
    enable = lib.mkEnableOption ''
      the local DRM/KMS display that mirrors the captured HDMI-IN feed to one of
      the Pi4B's own micro-HDMI outputs. Beyond-stock; opt-in'';

    mode = lib.mkOption {
      type = lib.types.enum [
        "fixed"
        "auto"
        "both"
      ];
      default = "fixed";
      description = ''
        Which micro-HDMI shows the capture vs stays the console.

        `fixed` (default): capture is PINNED to `captureConnector`; the OTHER
        micro-HDMI keeps the system console (boot log + login getty). The Pi4
        gives each micro-HDMI its own CRTC, so the render binds only the capture
        connector and the console stays on the other. Deterministic port roles.

        `auto`: capture FOLLOWS whichever micro-HDMI is connected and re-renders
        when the cable moves. No reserved console connector. NOTE: the exact
        unplug/replug/move recovery is not yet HW-characterized.

        `both`: mirror capture to both outputs, no console — NOT YET IMPLEMENTED
        (eval-errors); semantics pending.
      '';
    };

    captureConnector = lib.mkOption {
      type = lib.types.enum [
        "HDMI-A-1"
        "HDMI-A-2"
      ];
      default = "HDMI-A-2";
      description = ''
        In `fixed` mode, which micro-HDMI shows the capture; the OTHER stays the
        console. Physical map: `HDMI-A-1` = HDMI0 (nearest the USB-C power jack),
        `HDMI-A-2` = HDMI1. Ignored in `auto` (follows the cable) and `both`.
      '';
    };

    source = lib.mkOption {
      type = lib.types.enum [
        "v4l2"
        "mjpeg"
      ];
      default = "v4l2";
      description = ''
        Where the player reads video from.

        `v4l2` (default): read the capture device directly — measured working at
        1080p30. Lower latency, but the device is SINGLE-OPEN, so while local
        display runs the web UI's video is unavailable (they can't both hold
        /dev/kvmd-video). The service logs this loudly.

        `mjpeg`: consume the shared ustreamer MJPEG stream so the browser UI keeps
        working too. Relies on mpv-as-a-persistent-client keeping kvmd's on-demand
        streamer alive — UNVERIFIED on HW (if kvmd drops it, an explicit always-on
        config is the follow-up).
      '';
    };

    streamUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://127.0.0.1/streamer/stream";
      description = ''
        MJPEG stream URL for `source = "mjpeg"`. Defaults to the loopback nginx
        streamer endpoint; that vhost is self-signed TLS so the player is invoked
        with certificate verification disabled. Ignored for `v4l2`.
      '';
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/kvmd-video";
      description = "V4L2 capture device for `source = \"v4l2\"`.";
    };

    captureResolution = lib.mkOption {
      type = lib.types.str;
      default = "1920x1080";
      description = ''
        Capture resolution for the `v4l2` demuxer hint (`WIDTHxHEIGHT`). Default is
        the capture dongle's hardware ceiling (measured) — there is no higher mode
        to select.
      '';
    };

    captureFramerate = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Capture framerate for the `v4l2` demuxer hint.";
    };

    drmDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/dri/card1";
      description = ''
        DRM device node to render through. null = the player's default (auto);
        set it if the vc4 card is not the player's first pick.
      '';
    };

    package = lib.mkPackageOption pkgs "mpv" { };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra arguments appended to the player invocation. Defaults target mpv
        (`--vo=drm`); a different `package` will need its own flags here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # `both` is a specced-but-unimplemented mode: make it uneval-able rather than
    # let it silently fall through to the auto/first-connected path.
    assertions = [
      {
        assertion = cfg.mode != "both";
        message = ''
          services.pikvm.localDisplay.mode = "both" (mirror to both micro-HDMI
          outputs) is not yet implemented — its semantics are still being locked.
          Use "fixed" or "auto".
        '';
      }
    ];

    systemd.services.pikvm-local-display = {
      description = "PiKVM local DRM display (mirror captured HDMI-IN to a micro-HDMI output)";
      wantedBy = [ "multi-user.target" ];
      # kvmd owns the ustreamer subprocess that serves the MJPEG stream, so the
      # stream exists once kvmd is up. Not BindsTo/Requires: a streamer hiccup
      # should not tear the display down — the supervisor retries.
      after = [ "kvmd.service" ];
      wants = [ "kvmd.service" ];
      serviceConfig = {
        ExecStart = lib.getExe runner;
        Restart = "always";
        RestartSec = 5;
        # Run on a dedicated VT so mpv's DRM backend can do VT control (otherwise
        # it logs "Can't open TTY for VT control"). it-03400 measured this direct
        # path taking the CRTC cleanly — openvt was rejected (it leaves stale VT
        # state that breaks the next start).
        TTYPath = "/dev/tty2";
        StandardInput = "tty-force";
        StandardOutput = "journal";
        StandardError = "journal";
        TTYReset = true;
        TTYVTDisallocate = true;
        # DRM/KMS render + (for v4l2) the capture device live in these groups.
        SupplementaryGroups = [
          "video"
          "render"
        ];
        DeviceAllow = [
          "char-drm rw"
        ]
        ++ lib.optional (cfg.source == "v4l2") "${cfg.device} rw";
        # Moderate hardening — the player needs GPU/DRM, so no ProtectSystem=strict
        # sandbox that would hide /dev/dri; tighten once a live run shows what it
        # actually touches.
        NoNewPrivileges = true;
        ProtectHome = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
      };
    };
  };
}
