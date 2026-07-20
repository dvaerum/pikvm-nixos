# The `pikvm` package scope. `scope` is the makeScope self (so derivations can
# reference each other via scope.callPackage), and `pkgs` is the underlying
# nixpkgs (for e.g. the pinned Python package set).
{ scope, pkgs }:
let
  # kvmd pins Python >=3.14,<3.15; build it and its Python deps against that.
  pythonPackages = pkgs.python314Packages;
  luma-oled = pythonPackages.callPackage ./python/luma-oled { };
in
{
  ustreamer = scope.callPackage ./ustreamer { };

  inherit luma-oled;
  kvmd = pythonPackages.callPackage ./kvmd {
    inherit luma-oled;
    # Xlib is `xlib` on 26.05 and `python-xlib` on unstable — accept either so
    # kvmd builds regardless of which nixpkgs the consuming system uses.
    xlib = pythonPackages.xlib or pythonPackages.python-xlib;
  };
}
