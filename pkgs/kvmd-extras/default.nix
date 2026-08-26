# The kvmd `extras` this flake advertises in /api/info?fields=extras: kvmd's own
# extras dir MINUS the ones whose backing daemon we don't package. kvmd 4.188
# ships only `ipmi` (manifest daemon: kvmd-ipmi) and `vnc` (daemon: kvmd-vnc) —
# we run neither, so advertising them makes the dashboard query dead services
# (a DBusError on every /api/info). Exclude them by name.
#
# The filter is future-proof: it readDir's kvmd's extras, so an extra we later
# package (with its daemon) appears automatically, while ipmi/vnc stay excluded
# until their daemons are packaged. On kvmd 4.188 the result is an EMPTY dir
# (ipmi + vnc are the only two extras kvmd ships). webterm is NOT here — it is
# added separately by kvmd-webterm, which composes it on top of this dir.
{
  lib,
  linkFarm,
  kvmd,
}:
let
  # Extras whose systemd daemon this flake does not provide (see each extra's
  # manifest.yaml `daemon:` field). Add a name here only while its daemon is
  # unpackaged; remove it once we ship the daemon so the extra lights up.
  unpackaged = [
    "ipmi"
    "vnc"
  ];
  # `${kvmd.src}/extras`, NOT `${kvmd}/share/kvmd/extras` — this used to
  # readDir kvmd's BUILT output, a genuine Import-From-Derivation: `nix flake
  # check --no-build` (CI's eval job) hard-refuses the implicit kvmd build
  # this forces, regardless of allow-import-from-derivation, breaking CI on a
  # genuinely empty store (a locally-cached kvmd build masks it, which is why
  # this passed locally while failing on every real CI run — see
  # georgs-mac-mini's finding, 2026-08-26). kvmd's postInstall
  # (pkgs/kvmd/default.nix) copies `extras` from the unpacked SOURCE tree
  # verbatim (`cp -r firmware hid web extras contrib/keymaps "$out/share/kvmd/"`)
  # — confirmed none of kvmd's substituteInPlace edits touch anything under
  # extras/ (they're all scoped to kvmd/*.py) — so `kvmd.src` (a
  # fetchFromGitHub fixed-output derivation, realized as a content-addressed
  # fetch rather than an arbitrary build) has byte-identical content here.
  src = "${kvmd.src}/extras";
  wanted = lib.filter (name: !(lib.elem name unpackaged)) (
    lib.attrNames (builtins.readDir src)
  );
in
linkFarm "kvmd-extras" (map (name: {
  inherit name;
  path = "${src}/${name}";
}) wanted)
