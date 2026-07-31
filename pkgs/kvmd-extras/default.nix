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
  src = "${kvmd}/share/kvmd/extras";
  wanted = lib.filter (name: !(lib.elem name unpackaged)) (
    lib.attrNames (builtins.readDir src)
  );
in
linkFarm "kvmd-extras" (map (name: {
  inherit name;
  path = "${src}/${name}";
}) wanted)
