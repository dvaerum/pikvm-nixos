# The `ustreamer` Python module — µStreamer's CPython extension that reads
# captured frames from its memsink shared memory. kvmd imports it directly
# (`import ustreamer` in kvmd/clients/streamer.py), so kvmd cannot start
# without it. Upstream Arch ships it inside the `ustreamer` package; we build
# it here from the same source as the C binary (pkgs/ustreamer) so the two
# always share a version.
{
  lib,
  buildPythonPackage,
  setuptools,
  ustreamer,
}:
buildPythonPackage {
  pname = "ustreamer";
  inherit (ustreamer) version;
  pyproject = true;

  # Same source as the C streamer; the Python extension lives in python/.
  inherit (ustreamer) src;
  sourceRoot = "${ustreamer.src.name}/python";

  build-system = [ setuptools ];

  # The extension only links librt/libm/libpthread (all in libc); no deps.
  pythonImportsCheck = [ "ustreamer" ];

  meta = {
    homepage = "https://github.com/pikvm/ustreamer";
    description = "Python memsink bindings for µStreamer (imported by kvmd)";
    license = lib.licenses.gpl3Plus;
    inherit (ustreamer.meta) platforms;
  };
}
