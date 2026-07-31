# kvmd-webterm — PiKVM's web Terminal (ttyd) static artifacts, a faithful port of
# pikvm/packages @ packages/kvmd-webterm (v0.50). This derivation lays out ONLY
# the static files kvmd + nginx look for; ttyd, the systemd unit, and the
# kvmd-webterm user are wired by the NixOS module (services.pikvm.web.terminal).
#
# kvmd's own share/kvmd/{extras,web} is a read-only /nix/store path, so the module
# can't drop webterm into it. Instead we expose two COMPOSED dirs (passthru) that
# merge kvmd's assets with webterm's — the module points kvmd.info.extras / the
# nginx root / the nginx-include globs at them, so no kvmd package patch is needed.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  symlinkJoin,
  kvmd,
  ttyd,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "kvmd-webterm";
  version = "0.50"; # pikvm/packages packages/kvmd-webterm PKGBUILD pkgver

  # Sparse-checkout only the webterm package dir out of the (large) Arch packaging
  # repo; the four files below are committed there verbatim.
  src = fetchFromGitHub {
    owner = "pikvm";
    repo = "packages";
    rev = "7100665a510b7eb223917d1e501c99cd47f10aad";
    sparseCheckout = [ "packages/kvmd-webterm" ];
    hash = "sha256-Oob7Y0LlpG1LUeabqqQRJORLhe2L5WPJoz+dQMFsF+A=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    d=packages/kvmd-webterm
    # nginx include fragments + the extras manifest (kvmd.info.extras + the nginx
    # extras/*/nginx.ctx-{http,server}.conf include globs read these).
    install -Dm644 "$d/manifest.yaml"         -t "$out/share/kvmd/extras/webterm/"
    install -Dm644 "$d/nginx.ctx-http.conf"   -t "$out/share/kvmd/extras/webterm/"
    install -Dm644 "$d/nginx.ctx-server.conf" -t "$out/share/kvmd/extras/webterm/"
    # The menu icon, at the web-root path manifest.yaml references.
    install -Dm644 "$d/terminal.svg"          -t "$out/share/kvmd/web/extras/webterm/"
    runHook postInstall
  '';

  passthru = {
    # ttyd the module's kvmd-webterm.service runs (upstream depends ttyd>=1.7.7).
    inherit ttyd;

    # kvmd's own extras (ipmi, vnc, …) ∪ webterm — the module sets
    # kvmd.info.extras to this AND nginx-includes
    # ${extrasDir}/*/nginx.ctx-{http,server}.conf (kvmd's stock nginx.conf.mako
    # uses exactly that glob to self-register each extra).
    extrasDir = symlinkJoin {
      name = "kvmd-extras-with-webterm";
      paths = [
        "${kvmd}/share/kvmd/extras"
        "${finalAttrs.finalPackage}/share/kvmd/extras"
      ];
    };

    # kvmd's web UI ∪ the webterm menu icon — the module serves nginx `/` from
    # this so /extras/webterm/terminal.svg resolves.
    webDir = symlinkJoin {
      name = "kvmd-web-with-webterm";
      paths = [
        "${kvmd}/share/kvmd/web"
        "${finalAttrs.finalPackage}/share/kvmd/web"
      ];
    };
  };

  meta = {
    description = "PiKVM web Terminal (ttyd) static artifacts + composed extras/web dirs for the NixOS module";
    homepage = "https://github.com/pikvm/packages";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
