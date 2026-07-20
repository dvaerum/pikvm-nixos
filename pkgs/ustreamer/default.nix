# µStreamer — the MJPG/H.264 V4L2 streamer PiKVM uses to push the captured
# HDMI signal to the browser.
#
# We own this derivation (rather than reusing nixpkgs') so the version tracks
# exactly what kvmd's `ustreamer>=` bound expects, and so we can enable
# WITH_GPIO — PiKVM drives HAT GPIO (ATX power, LEDs) through µStreamer, which
# the nixpkgs build leaves out.
{
  lib,
  stdenv,
  fetchFromGitHub,
  pkg-config,
  which,
  libbsd,
  libevent,
  libjpeg,
  libgpiod,
  systemdLibs,
  # Janus (WebRTC/H.264) pulls in a large stack; off by default. The
  # kvmd-janus/media path can flip it on once WebRTC is wired up.
  janus-gateway,
  glib,
  alsa-lib,
  jansson,
  speex,
  libopus,
  withGpio ? true,
  withSystemd ? true,
  withJanus ? false,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "ustreamer";
  version = "6.61";

  src = fetchFromGitHub {
    owner = "pikvm";
    repo = "ustreamer";
    tag = "v${finalAttrs.version}";
    hash = "sha256-MSZJrYSxm+6vVvJ4dBaS7/N63fBOpi+uLXU82dgmKIY=";
  };

  nativeBuildInputs = [
    pkg-config
    which
  ];

  buildInputs = [
    libbsd # WITH_SETPROCTITLE (on by default) links -lbsd on Linux
    libevent
    libjpeg
  ]
  ++ lib.optionals withGpio [ libgpiod ]
  ++ lib.optionals withSystemd [ systemdLibs ]
  ++ lib.optionals withJanus [
    janus-gateway
    glib
    alsa-lib
    jansson
    speex
    libopus
  ];

  makeFlags = [
    "PREFIX=${placeholder "out"}"
  ]
  ++ lib.optionals withGpio [ "WITH_GPIO=1" ]
  ++ lib.optionals withSystemd [ "WITH_SYSTEMD=1" ]
  ++ lib.optionals withJanus [
    "WITH_JANUS=1"
    # Janus ships its headers under include/janus; the plugin build expects
    # them on the include path. See docs/h264.md in upstream.
    "CFLAGS=-I${lib.getDev janus-gateway}/include/janus"
  ];

  enableParallelBuilding = true;

  meta = {
    homepage = "https://github.com/pikvm/ustreamer";
    description = "Lightweight and fast MJPG-HTTP/H.264 V4L2 streamer (PiKVM)";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "ustreamer";
  };
})
