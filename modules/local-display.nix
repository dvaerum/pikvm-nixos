# PiKVM local display — an OPT-IN, beyond-stock service that renders the
# captured HDMI-IN feed to one of the appliance's OWN micro-HDMI (DRM/KMS)
# outputs, so a monitor cabled to the Pi mirrors the target's screen.
#
# This is the Pi4B-generic answer to "#52: local HDMI-out mirrors capture". It
# is the equivalent of PiKVM's V4-Plus HDMI passthrough (docs.pikvm.org/pass),
# which is DEDICATED-output hardware we don't have — but a Pi4B has two
# micro-HDMI KMS outputs, and our rpi4 host already enables `vc4-kms-v3d`
# (rendered config.txt), so /dev/dri/card* exists and those outputs are usable
# DRM/KMS targets. The old "a Pi4 has no HDMI-OUT" note was true only of the
# V4-Plus passthrough FEATURE, never of the Pi — the hardware is present, it was
# merely unimplemented.
#
# This is "Option B" of the #52 feasibility: a fullscreen DRM/KMS player (mpv
# --vo=drm) showing the captured feed. Chosen over "Option A" (patching ustreamer
# WITH_V4P — a separate `ustreamer-v4p.bin` that hardcodes the V4-Plus card +
# `HDMI-A-2` connector with no CLI override, so it needs a carried source patch)
# because it needs NO ustreamer rebuild. it-03400 measured the mpv path live on
# real appliance silicon at 1080p30.
#
# Two capture sources, a genuine product trade-off (default = v4l2, the measured
# one — see `source`):
#   * v4l2  — read /dev/kvmd-video directly. Measured working at 1080p30. Simple,
#             low latency, but the capture device is SINGLE-OPEN, so the web
#             stream and local display are mutually exclusive.
#   * mjpeg — consume the shared ustreamer MJPEG stream so the browser UI keeps
#             working too — but ustreamer is on-demand, so this needs the
#             streamer forced always-on (see the note on `source`).
#
# ⚠️ HELD: opt-in (default off), NOT enabled on any host yet. The DRM path itself
# is PROVEN — georg has seen the captured feed on the local monitor from a
# hand-run mpv (it-03400's test). What this MODULE still needs confirmed before
# deploy is narrower: that its OWN service wiring (dedicated VT + the
# wrapper-derived connector) renders the same picture, the tuned mode
# (--drm-mode for a native 1:1 image vs the soft upscale), and georg's greenlight
# on the default source (below) — NOT the existence question, which is answered.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.localDisplay;

  connectorPin = if cfg.connector == null then "" else cfg.connector;

  # Player args (mpv-shaped), WITHOUT the binary and WITHOUT --drm-connector
  # (the connector is resolved at runtime by the wrapper below).
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
        # LOAD-BEARING: without input_format=mjpeg the dongle negotiates raw
        # YUYV over USB2 and drops to ~5 fps at 1080p (measured, it-03400). The
        # MJPEG hint is what buys 30 fps.
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

  # SUPERVISOR, not a one-shot: georg's cable physically moves between the two
  # micro-HDMI ports, and a pinned/one-shot --drm-connector can't follow it (it
  # fails "Chosen connector is disconnected" on re-plug — measured, it-03400). So
  # this loops: it renders on whichever HDMI-A output is `connected`, and when the
  # connected connector CHANGES (a move, or unplug→replug), it kills the player and
  # re-renders on the new one. Surgical by design — it re-renders only on a real
  # connector change, not on every (often benign) DRM uevent a udev-restart would
  # fire on. Poll cadence is 2s. Set `connector` to pin a port and disable following.
  runner = pkgs.writeShellApplication {
    name = "pikvm-local-display";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
    ];
    # NOT errexit — a supervisor loop must survive the player exiting and an
    # unplugged (no-connector) poll without dying.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = ''
      # Echo the first `connected` HDMI-A connector name (e.g. HDMI-A-1), or "".
      current_connector() {
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

      pin=${lib.escapeShellArg connectorPin}
      mpv_pid=""
      cleanup() { if [ -n "$mpv_pid" ]; then kill "$mpv_pid" 2>/dev/null || true; fi; }
      trap cleanup EXIT
      ${lib.optionalString (cfg.source == "v4l2") ''
        # The capture device is single-open: while this holds it, the web KVM's
        # video is unavailable (first grabber wins). Say so loudly — a dark remote
        # view is otherwise a silent, confusing failure of the KVM's main job.
        echo "pikvm-local-display: source=v4l2 holds ${cfg.device} EXCLUSIVELY — the web UI video is UNAVAILABLE while this runs." >&2
      ''}

      while true; do
        if [ -n "$pin" ]; then target="$pin"; else target="$(current_connector)"; fi
        if [ -z "$target" ]; then
          echo "pikvm-local-display: no connected HDMI-A output; waiting for hotplug" >&2
          sleep 2
          continue
        fi
        echo "pikvm-local-display: rendering on connector $target" >&2
        ${lib.getExe cfg.package} --drm-connector="$target" ${lib.escapeShellArgs playerArgs} &
        mpv_pid=$!
        # Follow the cable: re-render if the connected connector changes underneath us.
        while kill -0 "$mpv_pid" 2>/dev/null; do
          sleep 2
          if [ -z "$pin" ]; then
            now="$(current_connector)"
            if [ "$now" != "$target" ]; then
              echo "pikvm-local-display: connector moved ($target -> ''${now:-none}); re-rendering" >&2
              kill "$mpv_pid" 2>/dev/null || true
              break
            fi
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
      the appliance's own micro-HDMI outputs. Beyond-stock; opt-in'';

    package = lib.mkPackageOption pkgs "mpv" { };

    source = lib.mkOption {
      type = lib.types.enum [
        "v4l2"
        "mjpeg"
      ];
      default = "v4l2";
      description = ''
        Where the local player reads video from.

        `v4l2` (default): read the capture device directly. This is the path
        measured working at 1080p30 on real hardware. Lower latency, but the
        capture device is SINGLE-OPEN — so while local display runs, the web UI's
        video is unavailable (they cannot both hold /dev/kvmd-video).

        `mjpeg`: consume the shared ustreamer MJPEG stream, so the browser UI
        keeps working simultaneously. Trade-off: ustreamer is ON-DEMAND (not
        running unless a stream client is connected), so this path needs the
        streamer forced always-on to be reliable — otherwise the player starts
        before any stream exists. Whether the player-as-client is enough to keep
        it up is unverified; treat `mjpeg` as needing that companion wiring.
      '';
    };

    streamUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://127.0.0.1/streamer/stream";
      description = ''
        MJPEG stream URL for `source = "mjpeg"`. Defaults to the loopback nginx
        streamer endpoint; since that vhost is self-signed TLS, the player is
        invoked with certificate verification disabled. Ignored for `v4l2`.
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
        Capture resolution for the `v4l2` demuxer hint (`WIDTHxHEIGHT`). Must be a
        mode the capture dongle actually emits over MJPEG.
      '';
    };

    captureFramerate = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Capture framerate for the `v4l2` demuxer hint.";
    };

    connector = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "HDMI-A-1";
      description = ''
        The DRM/KMS connector to render on. A Pi4B exposes `HDMI-A-1` and
        `HDMI-A-2` under vc4. null (default) = FOLLOW the cable: the service
        renders on whichever HDMI-A output is `connected` and re-renders on the
        other port when the cable moves (georg's hard requirement). Pin a name
        only to force a specific port and DISABLE following — note a pinned,
        unplugged connector then just waits for that port.
      '';
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

    freeConsole = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to stop the tty1 console getty while local display runs. Left OFF
        by default: the service runs on its OWN VT (tty2) and acquires DRM master
        there, so it should not need to evict the tty1 console. Enable only if a
        live run shows the console actually contending for the output.
      '';
    };

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
    systemd.services.pikvm-local-display = {
      description = "PiKVM local DRM display (mirror captured HDMI-IN to a micro-HDMI output)";
      wantedBy = [ "multi-user.target" ];
      # kvmd owns the ustreamer subprocess that serves the MJPEG stream, so the
      # stream exists once kvmd is up. Not BindsTo/Requires: a streamer hiccup
      # should not tear the display down — the player retries (Restart=always).
      after = [ "kvmd.service" ];
      wants = [ "kvmd.service" ];
      # Take the tty1 console off only when asked (see freeConsole).
      conflicts = lib.optional cfg.freeConsole "getty@tty1.service";
      serviceConfig = {
        ExecStart = lib.getExe runner;
        Restart = "always";
        RestartSec = 5;
        # Run on a dedicated VT so mpv's DRM backend can do VT control (otherwise
        # it logs "Can't open TTY for VT control") and switch the active console
        # to the rendered output.
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
        # Only the DRM devices (and, for v4l2, the capture node) are needed.
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
