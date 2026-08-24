# Janus WebRTC gateway (Phase 3 of docs/faithful-pikvm-plan.md) — the
# low-latency H.264 video path. Off by default: it's new, unverified on real
# WebRTC/browser negotiation, and only produces a real picture on a CSI
# capture profile (MEASURED 2026-08-20 — kvmd's own stock v2-hdmiusb-rpi4.yaml
# never puts --h264-sink in the streamer command; only the *-hdmi-* CSI
# profiles do. This is upstream's own architecture, not a gap here: a USB
# capture dongle already hands ustreamer hardware-compressed MJPEG, so
# there's no raw frame data on the Pi side to feed the VideoCore H.264
# encoder without a wasteful decode round-trip). MJPEG (nginx.nix, kvmd.nix)
# is the functional path regardless of this option.
#
# What this module does NOT need to do, and why (measured, not assumed):
#   - services.pikvm.kvmd.ustreamer is untouched. --h264-sink is a CORE
#     ustreamer feature (present in --help with WITH_JANUS=0 too) — WITH_JANUS
#     only gates building the SEPARATE janus/ plugin subdirectory
#     (lib/ustreamer/janus/libjanus_ustreamer.so), which Janus itself loads.
#     The capture daemon kvmd already runs needs no rebuild.
#   - The three stock janus.jcfg / janus.plugin.ustreamer.jcfg /
#     janus.transport.websockets.jcfg templates carry ZERO Arch-specific
#     absolute paths (checked against the actual shipped files) — copied
#     verbatim, not templated.
#   - nginx's /janus/ws upstream (unix:/run/kvmd/janus-ws.sock) already
#     matches janus.transport.websockets.jcfg's ws_unix exactly, and
#     kvmd-nginx is already in the kvmd-janus group (modules/kvmd.nix) —
#     both predate this module, so no nginx.nix wiring needed beyond the
#     janus.js/adapter.js path patch already made there.
#
# STATIC CONFIG ONLY, DELIBERATELY: stock ships two service variants —
# kvmd-janus.service (STUN-probes the network on a timer and rewrites Janus's
# public-IP config for WAN/NAT traversal) and kvmd-janus-static.service
# (direct exec, fixed config). This module implements the STATIC one under
# the plain `kvmd-janus.service` name: a LAN appliance has no NAT to
# traverse, and depending on outbound STUN reachability would be a new,
# silent external dependency this repo doesn't otherwise have. If WAN/mobile
# access via Janus is ever wanted, the STUN-probing runner
# (kvmd.apps.janus.runner, already in the kvmd package) is the documented
# path — swap ExecStart for `kvmd-janus --run` with the same cmd/cmd-append
# machinery kvmd-otg already uses elsewhere in this repo.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.janus;
  kvmd = config.services.pikvm.kvmd.package;
  janusConfigsDefault = "${kvmd}/share/kvmd/configs.default/janus";
  ustreamerJanus = pkgs.pikvm.ustreamer-janus;
in
{
  options.services.pikvm.janus = {
    enable = lib.mkEnableOption ''
      the Janus WebRTC gateway (H.264 low-latency video). Only produces a
      real picture on a CSI capture profile — see this file's header. MJPEG
      keeps working either way.
    '';
  };

  config = lib.mkIf cfg.enable {
    # kvmd-janus user/group already exist unconditionally — modules/kvmd.nix
    # creates the full kvmd system-user set (from upstream sysusers.conf,
    # including kvmd-janus's [kvmd, audio] extraGroups and kvmd-nginx's
    # membership in kvmd-janus) whether or not this module is enabled, so
    # this module only needs the service, not the identity.
    assertions = [
      {
        assertion = config.services.pikvm.kvmd.enable;
        message = "services.pikvm.janus requires services.pikvm.kvmd.enable "
          + "(the kvmd-janus user/group and /run/kvmd both come from there).";
      }
    ];

    # The three stock configs are copied verbatim (no Arch paths inside them
    # — see the header note) so `--configs-folder=/etc/kvmd/janus` matches
    # every other kvmd config living under /etc/kvmd.
    environment.etc = {
      "kvmd/janus/janus.jcfg".source = "${janusConfigsDefault}/janus.jcfg";
      "kvmd/janus/janus.plugin.ustreamer.jcfg".source =
        "${janusConfigsDefault}/janus.plugin.ustreamer.jcfg";
      "kvmd/janus/janus.transport.websockets.jcfg".source =
        "${janusConfigsDefault}/janus.transport.websockets.jcfg";
    };

    systemd.tmpfiles.rules = [
      # UMask=0117 below (matching stock) leaves the socket group-writable;
      # /run/kvmd already exists (modules/kvmd.nix creates it 0775 kvmd:kvmd)
      # but the socket file itself needs kvmd-janus as its creating user.
      "d /run/kvmd 0775 kvmd kvmd -"
    ];

    systemd.services.kvmd-janus = {
      description = "PiKVM - Janus WebRTC Gateway";
      wants = [ "network-online.target" ];
      after = [
        "network.target"
        "network-online.target"
        "nss-lookup.target"
        "kvmd.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "kvmd-janus";
        Group = "kvmd-janus";
        Type = "simple";
        Restart = "always";
        RestartSec = 3;
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        LimitNOFILE = 65536;
        # "Crutch for UNIX socket perms" — stock's own comment, kept verbatim
        # because it's still true: this is what makes janus-ws.sock come out
        # group-writable so kvmd-nginx (a kvmd-janus group member) can read it.
        UMask = "0117";
        ExecStart = "${pkgs.janus-gateway}/bin/janus --disable-colors "
          + "--plugins-folder=${ustreamerJanus}/lib/ustreamer/janus "
          + "--configs-folder=/etc/kvmd/janus";
        TimeoutStopSec = 10;
        KillMode = "mixed";
      };
    };
  };
}
