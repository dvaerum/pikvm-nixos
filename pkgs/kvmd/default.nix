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
}:
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
      --replace-fail 'ctypes.util.find_library("tesseract")' '"${lib.getLib tesseract}/lib/libtesseract.so.5"'
  '';

  pythonImportsCheck = [ "kvmd" ];

  meta = {
    homepage = "https://github.com/pikvm/kvmd";
    description = "The main PiKVM daemon (KVM-over-IP for Raspberry Pi)";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "kvmd";
  };
}
