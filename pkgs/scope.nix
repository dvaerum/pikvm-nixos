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
in
{
  inherit ustreamer luma-oled ustreamer-python;
  kvmd = pythonPackages.callPackage ./kvmd {
    inherit luma-oled ustreamer-python;
    # Xlib is `xlib` on 26.05 and `python-xlib` on unstable — accept either so
    # kvmd builds regardless of which nixpkgs the consuming system uses.
    xlib = pythonPackages.xlib or pythonPackages.python-xlib;
  };

  # PiKVM web Terminal static artifacts (ttyd). `kvmd` resolves from this scope;
  # `ttyd` from nixpkgs. Exposes passthru.{extrasDir,webDir,ttyd} for the module.
  kvmd-webterm = scope.callPackage ./kvmd-webterm { };
}
