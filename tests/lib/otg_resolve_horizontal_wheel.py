#!/usr/bin/env python3
"""Resolve the EFFECTIVE hid.mouse.horizontal_wheel value for a live kvmd
install, so a caller of otg_assert_mode.py isn't required to already know it.

WHY THIS EXISTS: report_length and the descriptor bytes both depend on
horizontal_wheel -- the same logical mode has a different correct gadget with
the wheel on or off (see otg-mode-specs.json's README). Every caller of
otg_assert_mode.py used to be hand-fed the value via --horizontal-wheel,
which is fine until the wrong one gets typed: the caller doesn't get
NOT-VERIFIED for that mistake, they get a straight FALSE RED against a
perfectly correctly-assembled gadget. That is worse than not checking at
all, because it looks like a real defect. This script removes the guess.

RESOLUTION ORDER (this is the whole design, get it right in this order):
  1. An explicit value in kvmd's config chain: main.yaml, then
     override.d/*.yaml sorted by filename, then override.yaml -- last one to
     set the key wins, matching kvmd's own merge order.
  2. Else the INSTALLED kvmd's own schema default for
     hid.mouse.horizontal_wheel (kvmd.plugins.hid.otg.Plugin
     .get_plugin_options()["mouse"]["horizontal_wheel"].default). This is a
     MEASUREMENT of the kvmd version actually installed, not a hardcoded
     True that would silently rot the day kvmd changes its default.
  3. Else NOT-VERIFIED. This script never guesses a value nobody can point to.

WHY LEG 1 CANNOT BE SKIPPED: 'desktop' mode leaves horizontal_wheel entirely
unset in the config chain (it only pins mouse.absolute), so leg 2 alone is
correct there -- but 'ipad' mode's override (modules/kvmd.nix, ipadSettings)
DOES set it to false explicitly, so leg 2 alone would silently report the
wrong value for every iPad-mode rig. Both legs are load-bearing today, not
hypothetically.

WHY LEG 2 READS THE INSTALLED PACKAGE INSTEAD OF `kvmd-otg --dump-config`:
that command prints the fully-merged config as human-oriented YAML with
inline '### Default: ...' annotations -- and MEASURED (2026-08-17) against
the real appliance, that output is not always valid strict YAML: a long
default value (kvmd.info.hw.vcgencmd_cmd) wraps across lines in a way
yaml.safe_load rejects, which would make a dump-config-based resolver
NOT-VERIFIED on every box that happens to hit that wrap, for a reason that
has nothing to do with horizontal_wheel. Importing the plugin class directly
and reading its own declared Option default sidesteps that formatting layer.

NO BARE `python3` ON THE APPLIANCE: MEASURED (2026-08-17) -- the appliance's
PATH has no system python3 at all; only kvmd's own Nix-wrapped interpreters
exist, and only THOSE have PyYAML and kvmd importable. So this script cannot
assume it is already running under a capable interpreter. On start, if
`yaml` doesn't import, it finds a Nix-wrapped kvmd-* binary (--kvmd-bin),
reads the exact interpreter path and the exact transitive site-packages
closure Nix computed for that build out of its wrapper file
(bin/.<name>-wrapped, next to the shell shim), and re-execs itself under
that interpreter with PYTHONPATH set to that closure. MEASURED: hand-picking
a subset of that closure (e.g. "just kvmd + evdev") is NOT safe -- evdev
alone pulled a mismatched build lacking its compiled _input extension in one
trial, while the wrapper's own full closure worked first try both times. Use
the whole list Nix already resolved; don't second-guess it.

THE READ MUST FAIL LOUD. If the wrapper file doesn't have the expected
shape, if the import raises, or the option isn't there -- NOT-VERIFIED,
never a silently wrong answer. This is the one place upstream of every
otg_assert_mode.py call where a wrong guess would poison every result after
it, so it is the one place that must refuse to guess.
"""
from __future__ import annotations

import ast
import os
import re
import sys
from pathlib import Path

NOT_VERIFIED = 2


def fail(reason: str) -> None:
    print(f"NOT-VERIFIED  could not resolve hid.mouse.horizontal_wheel: {reason}",
          file=sys.stderr)
    sys.exit(NOT_VERIFIED)


# --- bootstrap: get onto an interpreter that actually has PyYAML + kvmd -----

_ADDSITEDIR_RE = re.compile(
    r"functools\.reduce\(lambda k, p: site\.addsitedir\(p, k\), (\[[^\]]*\])"
)


def _wrapper_closure(kvmd_bin: Path) -> tuple[str, list[str]]:
    """Return (interpreter, site_packages_paths) read out of kvmd_bin's own
    Nix wrapper -- the exact closure THIS install was built with, not a
    guess. Fails loud if the wrapper doesn't have the expected shape."""
    wrapped = kvmd_bin.parent / f".{kvmd_bin.name}-wrapped"
    if not wrapped.is_file():
        fail(f"expected a Nix-wrapped sibling at {wrapped}, found none -- "
             f"this kvmd build may not be wrapped the way this script assumes")
    text = wrapped.read_text(errors="ignore")

    first_line = text.splitlines()[0] if text else ""
    if not first_line.startswith("#!"):
        fail(f"{wrapped} has no shebang line -- can't find its interpreter")
    interpreter = first_line[2:].strip()

    m = _ADDSITEDIR_RE.search(text)
    if not m:
        fail(f"{wrapped} doesn't contain the expected site.addsitedir(...) "
             f"closure list -- kvmd's Nix wrapper shape may have changed")
    try:
        site_paths = ast.literal_eval(m.group(1))
    except Exception as ex:
        fail(f"couldn't parse the site-packages closure out of {wrapped}: {ex}")
    if not isinstance(site_paths, list) or not all(isinstance(p, str) for p in site_paths):
        fail(f"the closure list parsed out of {wrapped} isn't a list of strings")
    return interpreter, site_paths


def _can_already_resolve() -> bool:
    """True if THIS interpreter, unmodified, can do everything both legs
    need: parse YAML (leg 1) and import the actual kvmd plugin whose default
    leg 2 reads. Checking the harder of the two (the kvmd import) is the
    correct gate -- a dev shell that has kvmd importable will have PyYAML
    too (it's kvmd's own dependency), but the reverse measurably isn't true:
    this repo's own dev machine has a bare python3 with system PyYAML
    importable yet no kvmd on its path at all, which would otherwise look
    like "no bootstrap needed" and then fail leg 2 for an unrelated reason."""
    try:
        import kvmd.plugins.hid.otg  # noqa: F401
        return True
    except ImportError:
        return False


def _bootstrap(kvmd_bin_arg: (str | None)) -> None:
    """If this interpreter can't already do the imports both legs need,
    re-exec under the installed kvmd's own interpreter with its real
    dependency closure on PYTHONPATH. No-op when nothing needs borrowing, so
    this never adds a detour where it isn't needed."""
    if _can_already_resolve():
        return

    if not kvmd_bin_arg:
        fail("this interpreter can't import kvmd and --kvmd-bin wasn't given, "
             "so there's no way to borrow a capable one")
    kvmd_bin = Path(kvmd_bin_arg)
    if not kvmd_bin.is_file():
        fail(f"--kvmd-bin {kvmd_bin} does not exist")

    interpreter, site_paths = _wrapper_closure(kvmd_bin)
    env = dict(os.environ)
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = ":".join(site_paths) + (":" + existing if existing else "")
    if env.get("_OTG_HW_BOOTSTRAPPED_ONCE"):
        fail(f"re-exec under {interpreter} still can't import kvmd -- "
             f"the borrowed closure doesn't actually contain it")
    env["_OTG_HW_BOOTSTRAPPED_ONCE"] = "1"
    os.execve(interpreter, [interpreter, os.path.abspath(__file__), *sys.argv[1:]], env)
    # os.execve never returns on success.


# --- leg 1: explicit config chain -------------------------------------------

def _read_key(path: Path) -> (bool | None):
    """Read kvmd.hid.mouse.horizontal_wheel from one YAML file, or None if
    the file is absent, empty, or doesn't set that key. A file that exists
    but fails to PARSE is a harder error than "doesn't set the key" -- it
    means the chain itself is broken, which is worth failing loud over."""
    if not path.is_file():
        return None
    import yaml
    try:
        doc = yaml.safe_load(path.read_text())
    except Exception as ex:
        fail(f"{path} exists but does not parse as YAML: {ex}")
    if not isinstance(doc, dict):
        return None
    node = doc
    for key in ("kvmd", "hid", "mouse", "horizontal_wheel"):
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    if not isinstance(node, bool):
        fail(f"{path} sets kvmd.hid.mouse.horizontal_wheel to {node!r}, not a bool")
    return node


def resolve_from_chain(main_config: Path, override_dir: Path, override_config: Path) -> (bool | None):
    value = _read_key(main_config)
    if override_dir.is_dir():
        for name in sorted(os.listdir(override_dir)):
            if name.endswith(".yaml"):
                v = _read_key(override_dir / name)
                if v is not None:
                    value = v
    v = _read_key(override_config)
    if v is not None:
        value = v
    return value


# --- leg 2: the installed kvmd's own schema default -------------------------

def resolve_installed_default() -> bool:
    """Only reachable after _bootstrap() has ensured we're on an interpreter
    that can actually import kvmd, so this is a plain in-process import --
    no subprocess, no second closure lookup."""
    try:
        from kvmd.plugins.hid.otg import Plugin
    except Exception as ex:
        fail(f"couldn't import kvmd.plugins.hid.otg: {ex}")
    try:
        default = Plugin.get_plugin_options()["mouse"]["horizontal_wheel"].default
    except Exception as ex:
        fail(f"kvmd.plugins.hid.otg.Plugin.get_plugin_options() doesn't have the "
             f"expected mouse.horizontal_wheel shape: {ex}")
    if not isinstance(default, bool):
        fail(f"the installed default for mouse.horizontal_wheel is {default!r}, not a bool")
    return default


# --- entry point -------------------------------------------------------------

def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--main-config", default="/run/kvmd/main.yaml")
    ap.add_argument("--override-dir", default="/etc/kvmd/override.d")
    ap.add_argument("--override-config", default="/etc/kvmd/override.yaml")
    ap.add_argument("--kvmd-bin", default=None,
                     help="a Nix-wrapped kvmd-* binary (e.g. the kvmd-otg.service "
                          "ExecStart binary) to borrow PyYAML/kvmd from if this "
                          "interpreter doesn't already have them, and to read the "
                          "installed default from if the config chain doesn't set "
                          "the key")
    args = ap.parse_args()

    value = resolve_from_chain(Path(args.main_config), Path(args.override_dir), Path(args.override_config))
    source = "config chain"
    if value is None:
        value = resolve_installed_default()
        source = "installed default"

    print("true" if value else "false")
    print(f"# resolved from: {source}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    # The bootstrap needs --kvmd-bin before argparse has run (that's the
    # whole point -- argparse itself is fine on any interpreter, but leg 1
    # needs PyYAML to do anything). A minimal manual scan, not a second
    # argparse pass, so a malformed --kvmd-bin still gets argparse's normal
    # error message on the real parse below.
    _kvmd_bin = None
    for _i, _a in enumerate(sys.argv[1:]):
        if _a == "--kvmd-bin" and _i + 2 < len(sys.argv):
            _kvmd_bin = sys.argv[_i + 2]
        elif _a.startswith("--kvmd-bin="):
            _kvmd_bin = _a.split("=", 1)[1]
    _bootstrap(_kvmd_bin)
    sys.exit(main())
