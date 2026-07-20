# PiKVM package overlay.
#
# All PiKVM-specific derivations live in ../pkgs and are attached under a
# dedicated `pikvm` scope (via makeScope) rather than the top-level nixpkgs
# namespace. This keeps them composable, lets them call each other with
# callPackage, and avoids clobbering unrelated nixpkgs attributes.
final: prev:
{
  pikvm = prev.lib.makeScope final.newScope (
    scope: import ../pkgs/scope.nix { inherit scope; pkgs = final; }
  );
}
