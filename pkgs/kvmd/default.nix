# kvmd — the main PiKVM daemon (and its ~20 helper entry points).
#
# Upstream ships no install_requires in setup.py; the authoritative runtime
# dependency set lives in the Arch PKGBUILD `depends` array, mirrored below.
# Non-Python runtime tools (nginx, iptables, dnsmasq, ustreamer, …) are
# supplied by the NixOS module's PATH rather than baked in here.
{
  lib,
  stdenv,
  buildPythonApplication,
  fetchFromGitHub,
  makeWrapper,

  # build-system
  setuptools,

  # Python runtime deps (from PKGBUILD `depends`)
  pyyaml,
  ruamel-yaml,
  aiohttp,
  aiofiles,
  async-lru,
  passlib,
  bcrypt,
  pyotp,
  qrcode,
  pyserial,
  pyserial-asyncio,
  spidev,
  setproctitle,
  psutil,
  netifaces,
  systemd-python, # python-systemd
  dbus-python,
  dbus-next,
  pygments,
  pyghmi,
  python-pam,
  pillow,
  xlib, # python Xlib (attr is `xlib` on 26.05)
  hidapi,
  six,
  pyrad,
  python-ldap,
  pysmbc,
  paramiko,
  zstandard,
  mako,
  luma-core,
  luma-oled,
  pyusb,
  pyudev,
  evdev,
  gpiod, # libgpiod v2 python bindings
  ustreamer-python, # `import ustreamer` — µStreamer's memsink module (pkgs/python/ustreamer)

  # Native libraries loaded via ctypes at runtime: libxkbcommon (keysym
  # translation, keyboard paste), tesseract (OCR of the captured screen).
  libxkbcommon,
  tesseract,
  util-linux, # `mount` for the MSD/PST remount helper (kvmd hardcodes /bin/mount)
  v4l-utils, # `v4l2-ctl` for kvmd-edidconf + the tc358743 EDID-loader unit (both hardcode /usr/bin/v4l2-ctl)
}:
let
  # kvmd's OCR (kvmd/apps/kvmd/ocr.py) both dlopens libtesseract AND, at
  # runtime, os.listdir()s a tessdata language dir (ocr.tessdata). kvmd's
  # ocr.langs default is ["eng"] (stock PiKVM's recognition language); we add
  # `osd` (orientation/script detection, a standard companion, ~10 MB) so the
  # set is eng+osd. The nixpkgs default `tesseract` instead bundles ALL ~130
  # languages, dragging a ~1.1 GiB tessdata closure into the appliance image;
  # restricting keeps the image small. We expose this exact package
  # (passthru.tesseract) so the NixOS module can point ocr.tessdata at the SAME
  # store path whose libtesseract.so.5 we link below (lib + language data stay
  # version-matched).
  tesseractOcr = tesseract.override { enableLanguages = [ "eng" "osd" ]; };
in
buildPythonApplication rec {
  pname = "kvmd";
  version = "4.188";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "pikvm";
    repo = "kvmd";
    tag = "v${version}";
    hash = "sha256-Z/X1RYBGogqsINHy8vJRflfK/42FIpPqyAZHtef97TE=";
  };

  build-system = [ setuptools ];

  nativeBuildInputs = [ makeWrapper ];

  dependencies = [
    pyyaml
    ruamel-yaml
    aiohttp
    aiofiles
    async-lru
    passlib
    bcrypt
    pyotp
    qrcode
    pyserial
    pyserial-asyncio
    spidev
    setproctitle
    psutil
    netifaces
    systemd-python
    dbus-python
    dbus-next
    pygments
    pyghmi
    python-pam
    pillow
    xlib
    hidapi
    six
    pyrad
    python-ldap
    pysmbc
    paramiko
    zstandard
    mako
    luma-core
    luma-oled
    pyusb
    pyudev
    evdev
    gpiod
    ustreamer-python
  ];

  # kvmd loads libxkbcommon.so.0 through ctypes; make it resolvable from the
  # wrapped entry points.
  makeWrapperArgs = [
    "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libxkbcommon ]}"
  ];

  # Tests exercise real hardware/serial/network; not meaningful in the sandbox.
  doCheck = false;

  postInstall = ''
    # Shell-script entry points that setuptools does not emit.
    install -Dm755 -t "$out/bin" \
      scripts/kvmd-bootconfig \
      scripts/kvmd-gencert \
      scripts/kvmd-certbot \
      scripts/kvmd-update-switch
    install -Dm755 -t "$out/lib/kvmd" scripts/kvmd-udev-flash-pico

    # Static assets and the pristine, read-only default config tree. The NixOS
    # module materialises the mutable /etc/kvmd from configs.default.
    mkdir -p "$out/share/kvmd"
    cp -r firmware hid web extras contrib/keymaps "$out/share/kvmd/"
    find "$out/share/kvmd/web" -name '*.pug' -delete
    cp -r configs "$out/share/kvmd/configs.default"

    # Ship the upstream systemd units / sysusers / tmpfiles for the module to
    # reference (the module itself declares services declaratively).
    find "$out/share/kvmd" -name '.gitignore' -delete
  '';

  # Fix #!/bin/bash etc. in the shipped scripts.
  postPatch = ''
    patchShebangs scripts

    # kvmd.libc loads libc via ctypes.util.find_library("c"), which returns
    # None at runtime on NixOS (no ld.so.cache / compiler in the service env),
    # so `kvmd.inotify` raises "Where is libc?" and every daemon importing it
    # (kvmd, kvmd-media, kvmd-otg) dies. Point it straight at glibc.
    substituteInPlace kvmd/libc.py \
      --replace-fail 'ctypes.util.find_library("c")' '"${lib.getLib stdenv.cc.libc}/lib/libc.so.6"'

    # kvmd-otg parses args twice: init() consumes --main-config, then its own
    # subcommand parser re-adds it (parents=[ia.parser]) and re-validates the
    # baked DEFAULT (whose value it then discards). The Arch default
    # /usr/lib/kvmd/main.yaml doesn't exist on NixOS, so that second validation
    # fails. Point the default at the runtime path the module materialises.
    substituteInPlace kvmd/apps/__init__.py \
      --replace-fail '"/usr/lib/kvmd/main.yaml"' '"/run/kvmd/main.yaml"'

    # Same find_library("...") -> None problem as libc above, for the two
    # feature-path native libs kvmd dlopens: libxkbcommon (keyboard paste /
    # keysym translation) and libtesseract (screen OCR). Unlike libc these are
    # imported lazily so they don't break boot, but the feature dies at runtime
    # on the appliance. Point both straight at the store lib.
    substituteInPlace kvmd/keyboard/printer.py \
      --replace-fail 'ctypes.util.find_library("xkbcommon")' '"${lib.getLib libxkbcommon}/lib/libxkbcommon.so.0"'
    substituteInPlace kvmd/apps/kvmd/ocr.py \
      --replace-fail 'ctypes.util.find_library("tesseract")' '"${lib.getLib tesseractOcr}/lib/libtesseract.so.5"'

    # kvmd-otg's add_msd() unconditionally writes the mass-storage lun attribute
    # `inquiry_string_cdrom`, which is a PiKVM-kernel patch NOT present in the
    # nixos-raspberrypi vendor kernel (nor a generic kernel). configfs returns
    # EACCES (not ENOENT) when opening a non-existent attribute for writing, so
    # this surfaces as PermissionError [Errno 13] and ABORTS gadget assembly
    # before the UDC is bound → the OTG gadget never binds → HID/MSD are dead
    # (no /dev/kvmd-hid-*, keyboard/mouse online=false), independent of cabling.
    # kvmd already guards other kernel-version-dependent attrs (no_out_endpoint,
    # wakeup_on_write) with optional=True; give inquiry_string_cdrom the same
    # treatment so assembly skips it when absent and proceeds to the UDC bind.
    # (`inquiry_string` — the flash-mode string — DOES exist, so it stays
    # mandatory.) The only effect of skipping is that CDROM-mode MSD uses the
    # default SCSI inquiry string rather than a cdrom-specific one — cosmetic.
    substituteInPlace kvmd/apps/otg/__init__.py \
      --replace-fail \
        '_write(join(func_path, "lun.0/inquiry_string_cdrom"), inquiry_string_cdrom)' \
        '_write(join(func_path, "lun.0/inquiry_string_cdrom"), inquiry_string_cdrom, optional=True)'

    # The MSD/PST remount helper (kvmd.helpers.remount, run as root via sudo to
    # remount the virtual-drive storage RW/RO) hardcodes /bin/mount, which does
    # not exist on NixOS (/bin has only sh) → a RW remount would fail. Point it
    # at util-linux's mount (root-invoked, so the plain binary is fine).
    substituteInPlace kvmd/helpers/remount/__init__.py \
      --replace-fail '"/bin/mount"' '"${lib.getExe' util-linux "mount"}"'

    # kvmd-edidconf (the CSI/tc358743 EDID CLI) hardcodes two Arch FHS paths:
    # its --presets default (the shipped v0/v1/v2/v3/v4mini/v4plus.hex presets,
    # which DO exist — just under our store path, not /usr/share) and every
    # v4l2-ctl invocation it shells out to for --apply/--clear. Neither exists
    # on NixOS, so `kvmd-edidconf --import-preset v2 --apply` (needed once per
    # box to seed /etc/kvmd/tc358743-edid.hex — see modules/kvmd.nix's
    # kvmd-tc358743 unit, which loads that file at every boot) hard-fails with
    # FileNotFoundError on both counts. $out is this same derivation's own
    # output — self-referencing it here is standard (only the STRING needs to
    # be correct at substitute time; the tree doesn't need to exist yet).
    substituteInPlace kvmd/apps/edidconf/__init__.py \
      --replace-fail \
        '"/usr/share/kvmd/configs.default/kvmd/edid"' \
        "\"$out/share/kvmd/configs.default/kvmd/edid\"" \
      --replace-fail '"/usr/bin/v4l2-ctl"' '"${lib.getExe' v4l-utils "v4l2-ctl"}"'
  '';

  pythonImportsCheck = [ "kvmd" ];

  # The eng+osd tesseract kvmd links + reads tessdata from; the NixOS module
  # points ocr.tessdata at ${kvmd.tesseract}/share/tessdata (same store path).
  passthru.tesseract = tesseractOcr;

  meta = {
    homepage = "https://github.com/pikvm/kvmd";
    description = "The main PiKVM daemon (KVM-over-IP for Raspberry Pi)";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "kvmd";
  };
}
