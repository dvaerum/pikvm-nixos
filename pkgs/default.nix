# Flake `packages.<system>` output: every derivation in the `pikvm` scope,
# re-exported flat so `nix build .#ustreamer` etc. works. The scope itself is
# defined by ../overlays and grown via ./scope.nix.
{ pkgs }:
let
  inherit (pkgs) lib;
in
lib.filterAttrs (_name: v: lib.isDerivation v) pkgs.pikvm
