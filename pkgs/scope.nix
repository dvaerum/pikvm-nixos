# The `pikvm` package scope. `scope` is the makeScope self (so derivations can
# reference each other via scope.callPackage), and `pkgs` is the underlying
# nixpkgs (for e.g. the pinned Python package set).
{ scope, pkgs }:
let
  # kvmd pins Python >=3.14,<3.15; build it and its Python deps against that.
  pythonPackages = pkgs.python314Packages;
  luma-oled = pythonPackages.callPackage ./python/luma-oled { };
  ustreamer = scope.callPackage ./ustreamer { };
  # µStreamer's Python memsink module, built from the same source; kvmd does
  # `import ustreamer` and won't start without it.
  ustreamer-python = pythonPackages.callPackage ./python/ustreamer { inherit ustreamer; };
  # A separate named variant rather than flipping the default: withJanus
  # pulls in a large stack (janus-gateway, glib, alsa, ...) that most builds
  # of this flake never need. modules/janus.nix uses THIS package ONLY as the
  # source of the janus/ plugin .so the Janus DAEMON loads
  # (--plugins-folder=${ustreamer-janus}/lib/ustreamer/janus) — it deliberately
  # does NOT repoint services.pikvm.kvmd.ustreamer here (see that module's
  # header: --h264-sink is a core ustreamer flag independent of WITH_JANUS, so
  # kvmd's own capture subprocess stays on the lean default build either way).
  ustreamer-janus = ustreamer.override { withJanus = true; };
in
{
  inherit ustreamer luma-oled ustreamer-python ustreamer-janus;
  kvmd = pythonPackages.callPackage ./kvmd {
    inherit luma-oled ustreamer-python;
    # Xlib is `xlib` on 26.05 and `python-xlib` on unstable — accept either so
    # kvmd builds regardless of which nixpkgs the consuming system uses.
    xlib = pythonPackages.xlib or pythonPackages.python-xlib;
  };

  # The kvmd extras we actually advertise (kvmd's extras minus the ones whose
  # daemon we don't package — ipmi/vnc). Consumed by the kvmd module's base
  # info.extras and by kvmd-webterm's composed extrasDir.
  kvmd-extras = scope.callPackage ./kvmd-extras { };

  # PiKVM web Terminal static artifacts (ttyd). `kvmd` resolves from this scope;
  # `ttyd` from nixpkgs. Exposes passthru.{extrasDir,webDir,ttyd} for the module.
  kvmd-webterm = scope.callPackage ./kvmd-webterm { };

  # The browser-side Janus WebRTC client kvmd's stream_janus.js imports but
  # never ships itself. See pkgs/janus-web-client/default.nix.
  janus-web-client = scope.callPackage ./janus-web-client { };
}
