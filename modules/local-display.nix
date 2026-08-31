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
# `mode` governs which micro-HDMI(s) render the capture:
#   * fixed (DEFAULT): capture is PINNED to `captureConnector`, full stop. This is
#     a deliberately NARROWED promise (see the risk note below) — it does NOT
#     claim anything about the other micro-HDMI, which may go frozen/blank while
#     mpv holds it. Deterministic: a box always renders capture on a known port.
#   * auto: capture FOLLOWS whichever micro-HDMI is connected, re-rendering when
#     the cable moves (the hotplug supervisor). ⚠️ the exact unplug/replug/move
#     recovery is UNMEASURED on HW — needs an on-appliance characterization with
#     georg before `auto` is called proven.
# A `both` (mirror to both outputs) mode was drafted and dropped — not merely
# held: it needs semantics nobody has locked (which connector keeps a console?
# none, per the DRM-master finding below), so exposing it as a selectable enum
# value (even assertion-blocked) documented a capability that doesn't exist.
# Re-add it if/when the semantics are real, not before.
#
# ⚠️ Capture is capped at the DONGLE's 1920x1080 hardware ceiling (measured: UVC
# device, no higher mode, source timings unreadable). If the source outputs
# >1080p the dongle downscales IN HARDWARE — no module setting recovers it;
# sharpness beyond that is a source/dongle matter, out of scope here.
#
# ⚠️ RESOLVED (2026-08-24): `fixed` mode does NOT reserve a live console on the
# other micro-HDMI, and never will with mpv. Two independent mechanisms both rule
# it out: (1) VTs are global, not per-connector — fbcon renders the active VT on
# every output, so mpv switching VTs moves the console off all of them; (2) DRM
# master is per-DEVICE — both micro-HDMI are connectors on ONE vc4 card, so mpv
# taking master to drive its connector suspends fbcon device-wide, leaving the
# other connector frozen/blank rather than a live login. The only clean fix is DRM
# leasing one connector to the app while fbcon keeps the rest, which mpv does not
# do. This is a genuine mpv/DRM limitation, not a missing on-HW check — a
# two-monitor test would only confirm the mechanism above, not change the
# conclusion, so it is NOT a blocker for shipping `fixed` mode as scoped now.
# `fixed`'s promise is narrowed accordingly: it pins capture to a connector, full
# stop. The serial console (console=serial0) + SSH are the real, always-available
# admin fallback regardless of mode — they never depended on this feature.
#
# Opt-in (default off); no host enables it yet. Greenlit for deployment
# 2026-08-24 (georg) with `fixed` mode's promise narrowed as above — that closes
# the console-coexistence question, so it's no longer a blocker. Still open,
# tracked separately, not blocking `fixed`-mode deployment: the `auto`-mode
# unplug/replug/move recovery (needs an on-appliance characterization —
# it-03400) and a live two-monitor coexistence smoke-test (georg, opportunistic
# — the DRM-master conclusion above doesn't need it to be trusted, but seeing it
# firsthand is still worth doing when convenient).
#
# See docs/decisions/0004-local-display.md for the VM-testability design (the
# sysfsDrmRoot/vt options, the mpv-stub pattern, the DeviceAllow structural
# guard) added 2026-08-24.
#
# ⚠️ 2026-08-31 (task_c9df75066f71, georg via manager): the `v4l2` source mode
# is GONE — `mjpeg` (consuming ustreamer's own output through nginx) is now
# the ONLY mode. WHY: v4l2 opened /dev/kvmd-video directly, single-open, in
# genuine unrefereed contention with kvmd's own ustreamer for the SAME
# device — real, observed on it-03400 ("whichever restarts/retries first
# wins," no negotiation anywhere). The appliance's core function is the
# REMOTE video stream; local-display's HDMI-out mirror is secondary and must
# never be able to starve it. Removing the exclusive-open path is a
# structural fix (the race is architecturally impossible, not arbitrated) —
# not a toggle a future edit can flip back. See docs/decisions/0005-local-display-mjpeg-only.md.
#
# Paired with that: `streamer.forever` is now auto-set whenever this module
# is enabled (see `config` below) — mjpeg mode reads ustreamer's HTTP output
# via nginx, which kvmd's own idle-stop accounting (kvmd/apps/kvmd/server.py's
# `__stream_controller`, counts only kvmd's OWN WebSocket `stream=1` clients)
# is blind to; without `forever`, kvmd would silently kill ustreamer under an
# actively-streaming mpv once its own WS client count hits 0. Confirmed
# against kvmd 4.188's real source, not assumed.
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
  ++ [
    "--tls-verify=no" # loopback nginx streamer is self-signed
    cfg.streamUrl
  ]
  ++ cfg.extraArgs;

  # Supervisor. `mode` picks the target connector:
  #   fixed → the pinned captureConnector (only while it is `connected`)
  #   auto  → the first `connected` HDMI-A output, and re-render when that changes
  # In BOTH modes it re-renders when its chosen target's connection state changes,
  # so it survives an unplug→replug (fixed) or a cable move (auto). Surgical: it
  # acts only on a real target change, not on every (benign) DRM uevent.
  #
  # Nix-computed values are assigned as plain shell variables ABOVE the static,
  # readFile'd control-flow script (same idiom as hidmode.nix/hidmode-set.sh and
  # hid-recovery.nix/hid-recover.sh) — keeps the nix ${} interpolation out of the
  # part a test wants to exercise unmodified, and out of the part a reader has to
  # reason about as plain bash.
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
    text =
      ''
        mode=${lib.escapeShellArg cfg.mode}
        fixed_connector=${lib.escapeShellArg cfg.captureConnector}
        drm_root=${lib.escapeShellArg cfg.sysfsDrmRoot}
        mpv_exe=${lib.escapeShellArg (lib.getExe cfg.package)}
        player_args=(${lib.escapeShellArgs playerArgs})
        # Reads ustreamer's own output via nginx (never the raw capture
        # device) — the web KVM stays available while this runs, and
        # `streamer.forever` (auto-set below whenever this module is
        # enabled) keeps kvmd from idle-stopping ustreamer out from under it.
        echo "pikvm-local-display: reading the shared ustreamer stream via ${cfg.streamUrl} — the web UI stays available." >&2
      ''
      + builtins.readFile ./local-display-run.sh;
  };

  # Setting DeviceAllow AT ALL narrows systemd's default DevicePolicy=auto to
  # deny-by-default for the whole unit (man systemd.resource-control: auto
  # "allows access to all devices IF NO EXPLICIT DeviceAllow= IS PRESENT" —
  # the reported DevicePolicy VALUE stays "auto", only its effective
  # permissiveness narrows; see docs/learnings/systemd-devicepolicy-auto.md).
  # It doesn't just ADD an allowance, it also revokes the implicit access
  # every process normally has to its own controlling TTY. Without
  # "char-tty rw" here, this unit's own
  # TTYPath=/dev/tty<vt> + StandardInput=tty-force below is silently denied by
  # the SAME sandboxing that's supposed to scope down DRM/capture access,
  # crash-looping on "Permission denied" (exit 208/STDIN). HW-confirmed on a
  # real deploy (it-03400, 2026-08-24) — the fix alone made the reported
  # crash-loop stop AND auto-mode render for real (kernel-level scanout
  # check, not just the app's own self-report).
  #
  # STRUCTURAL GUARD, not just a comment: this is the ONLY place this pair is
  # written — the assertion in `config` fails eval loudly if it's ever
  # dropped, instead of silently reintroducing the crash. (No raw capture
  # device to allow here since 2026-08-31 — mjpeg-only, see the file header —
  # so this narrows the sandbox further than it used to, structurally: this
  # unit no longer CAN open /dev/kvmd-video even if a future edit tried.)
  deviceAllow = [
    "char-drm rw"
    "char-tty rw"
  ];

  ttyPath = "/dev/tty${toString cfg.vt}";
  gettyUnit = "getty@tty${toString cfg.vt}.service";
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
      ];
      default = "fixed";
      description = ''
        Which micro-HDMI renders the capture.

        `fixed` (default): capture is PINNED to `captureConnector`. Deterministic
        — a box always renders capture on a known port. This does NOT reserve a
        live console on the other micro-HDMI: DRM master is per-DEVICE on the
        vc4 card, so mpv holding master for its connector suspends fbcon
        device-wide — the other connector is frozen/blank, not a login prompt,
        for as long as this service runs. The serial console (console=serial0)
        and SSH are unaffected and remain the real admin fallback.

        `auto`: capture FOLLOWS whichever micro-HDMI is connected and re-renders
        when the cable moves. NOTE: the exact unplug/replug/move recovery is not
        yet HW-characterized.
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

    streamUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://127.0.0.1/streamer/stream";
      description = ''
        MJPEG stream URL the player reads from — the loopback nginx streamer
        endpoint (proxies to ustreamer, the SAME feed the web UI serves), never
        the raw capture device (see the file header for why: single-open
        contention with kvmd's own ustreamer, removed 2026-08-31). That vhost is
        self-signed TLS so the player is invoked with certificate verification
        disabled.
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

    package = lib.mkPackageOption pkgs "mpv" { };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra arguments appended to the player invocation. Defaults target mpv
        (`--vo=drm`); a different `package` will need its own flags here.
      '';
    };

    vt = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Virtual terminal the player runs on. `TTYPath` and the conflicting
        `getty@ttyN.service` unit are BOTH derived from this single value —
        previously typed twice (`/dev/tty2` in `TTYPath` and `2` in the getty
        unit reference), which could silently drift out of sync.
      '';
    };

    sysfsDrmRoot = lib.mkOption {
      type = lib.types.path;
      default = "/sys/class/drm";
      internal = true;
      description = ''
        Root the connector-detection supervisor globs under (`<root>/card*-
        <connector>/status`). Internal knob so tests can point it at fake
        connector/status files instead of real DRM sysfs — not meant to be
        set on a real deployment.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem "char-tty rw" deviceAllow;
        message = ''
          pikvm-local-display: DeviceAllow must always include "char-tty rw" —
          dropping it (while "char-drm rw" still narrows DevicePolicy=auto's
          effective access) denies this unit's own TTYPath/
          StandardInput=tty-force, crash-looping with Permission denied
          (HW-confirmed regression, it-03400 2026-08-24).
        '';
      }
    ];

    # Declarative, not a manual toggle a future re-image can lose (same
    # rationale hosts/pikvm01.nix already documents for its own reason).
    # mkDefault: a host that has some other explicit need can still override
    # it, but the module's own requirement — this mode must never let kvmd
    # idle-stop ustreamer out from under it, since kvmd's client-count
    # accounting can't see mjpeg's nginx-proxied HTTP connection at all (see
    # the file header) — holds by default whenever local-display is enabled.
    services.pikvm.kvmd.settings.kvmd.streamer.forever = lib.mkDefault true;

    systemd.services.pikvm-local-display = {
      description = "PiKVM local DRM display (mirror captured HDMI-IN to a micro-HDMI output)";
      wantedBy = [ "multi-user.target" ];
      # kvmd owns the ustreamer subprocess that serves the MJPEG stream, so the
      # stream exists once kvmd is up. Not BindsTo/Requires: a streamer hiccup
      # should not tear the display down — the supervisor retries.
      after = [
        "kvmd.service"
        gettyUnit
      ];
      wants = [ "kvmd.service" ];
      # NixOS's getty module aliases autovt@.service to getty@.service, and
      # logind hardcodes spawning autovt@ttyN.service on any VT switch — so
      # without this, a physical switch to the VT races a getty against mpv
      # for the tty device ownership (mirrors nixpkgs' own cage.nix, which
      # conflicts+afters getty@tty1.service for the identical reason: TTYPath
      # + a getty template both wanting the same VT). This is a systemd
      # TTY-ownership question, distinct from the DRM-master/fbcon
      # coexistence risk above — closing it doesn't touch that finding, just
      # stops the two units fighting over the device node itself.
      conflicts = [ gettyUnit ];
      serviceConfig = {
        ExecStart = lib.getExe runner;
        Restart = "always";
        RestartSec = 5;
        # Run on a dedicated VT so mpv's DRM backend can do VT control (otherwise
        # it logs "Can't open TTY for VT control"). it-03400 measured this direct
        # path taking the CRTC cleanly — openvt was rejected (it leaves stale VT
        # state that breaks the next start).
        TTYPath = ttyPath;
        StandardInput = "tty-force";
        StandardOutput = "journal";
        StandardError = "journal";
        TTYReset = true;
        TTYVTDisallocate = true;
        # DRM/KMS render lives in these groups.
        SupplementaryGroups = [
          "video"
          "render"
        ];
        DeviceAllow = deviceAllow;
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
