# luma.oled — OLED display driver used by kvmd-oled. Not in nixpkgs (only
# luma.core is), so we package it here against the same Python as kvmd.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  setuptools-scm,
  luma-core,
}:
buildPythonPackage rec {
  pname = "luma-oled";
  version = "3.15.0";
  pyproject = true;

  src = fetchPypi {
    # PyPI serves the sdist under the PEP 625 normalised name (underscores),
    # so the dotted "luma.oled" URL 404s.
    pname = "luma_oled";
    inherit version;
    hash = "sha256-FpJf5mj0hIA98Gg63YALGeXdcxah1k6wbsKugXRzkB4=";
  };

  build-system = [
    setuptools
    setuptools-scm
  ];

  dependencies = [ luma-core ];

  # Test suite pulls in extra mocking deps and simulated hardware; the module
  # is only exercised on real OLED hardware in this project.
  doCheck = false;

  pythonImportsCheck = [ "luma.oled" ];

  meta = {
    homepage = "https://github.com/rm-hull/luma.oled";
    description = "Python driver for SSD1306/SH1106/etc. OLED displays (luma.oled)";
    license = lib.licenses.mit;
  };
}
