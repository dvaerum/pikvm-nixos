# The browser-side Janus WebRTC client (`janus.js`), which kvmd's own
# `stream_janus.js` dynamically imports (`import("./janus.js")`) but never
# ships itself — MEASURED (2026-08-20): grepped kvmd's full upstream source
# tree, no janus.js anywhere. Stock PiKVM must get this from a separate Arch
# package; we get it from upstream Janus's own npm release instead.
#
# WHY THIS SOURCE: janus-gateway (the C daemon we package via nixpkgs)
# publishes a version-matched npm package with the SAME release number
# (1.4.1 here) containing a prebuilt ES-module bundle at
# npm/dist/janus.es.js — no npm/rollup build needed in this derivation, just
# fetch + verify + place. Pinned by exact version and sha256, same as every
# other vendored source in this flake.
#
# Also vendors adapter.js (webrtc-adapter, the cross-browser WebRTC shim) —
# stock kvmd's nginx config aliases /share/js/kvm/adapter.js to it
# unconditionally (kvmd.ctx-server.conf), so it needs to exist even though
# MEASURED (2026-08-20): kvmd's own index.html never references it directly
# — modern browsers mostly don't need the shim, but the alias existing and
# 404ing would be an unfaithful deviation same as janus.js was.
#
# THE SHIM, AND WHY IT EXISTS: MEASURED — the npm dist file only has
#   export { Janus as default };
# but kvmd's stream_janus.js does `module.Janus.init(...)` — a NAMED export,
# which this file doesn't provide. Rather than patch Meetecho's file (which
# would make the vendored artifact not byte-identical to what its hash
# claims to certify), this derivation ships the untouched upstream file
# alongside a two-line first-party shim that re-exports it under both names.
# kvmd's stream_janus.js imports the SHIM (named janus.js, matching the path
# it expects); the shim imports the real vendored bundle.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "janus-web-client";
  version = "1.4.1";

  adapterVersion = "9.0.6";

  src = fetchurl {
    url = "https://registry.npmjs.org/janus-gateway/-/janus-gateway-${finalAttrs.version}.tgz";
    hash = "sha256-6s1MbRScx65H3jss4m0FwzFi0ijJvyhNudyJndkKaMA=";
  };

  adapterSrc = fetchurl {
    url = "https://registry.npmjs.org/webrtc-adapter/-/webrtc-adapter-${finalAttrs.adapterVersion}.tgz";
    hash = "sha256-Nh5QZFoCCrL1mLXqdAq4HknbMqIuHFiOz942zodLQo4=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/janus-web-client"
    install -m444 npm/dist/janus.es.js "$out/share/janus-web-client/janus-vendor.es.js"
    cat > "$out/share/janus-web-client/janus.js" <<'JS'
    // First-party shim, NOT vendored — see pkgs/janus-web-client/default.nix
    // for why. Upstream's npm build only exports Janus as the module
    // default; kvmd's stream_janus.js reads it as a named export
    // (`module.Janus.init(...)`), so this re-exports it under both names.
    import Janus from "./janus-vendor.es.js";
    export { Janus };
    export default Janus;
    JS
    tar -xzf "${finalAttrs.adapterSrc}" -C "$TMPDIR" package/out/adapter.js
    install -m444 "$TMPDIR/package/out/adapter.js" "$out/share/janus-web-client/adapter.js"
    runHook postInstall
  '';

  meta = {
    description = "Meetecho's browser-side Janus WebRTC client (prebuilt ES module from the janus-gateway npm release), plus a named-export shim for kvmd's stream_janus.js";
    homepage = "https://github.com/meetecho/janus-gateway";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
