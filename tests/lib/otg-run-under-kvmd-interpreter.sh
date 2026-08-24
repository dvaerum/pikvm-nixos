#!/usr/bin/env bash
# Run a python script under the SAME interpreter kvmd-otg.service actually
# uses on this box, passing that binary's path to the script as --kvmd-bin.
#
# WHY THIS EXISTS: MEASURED (2026-08-17) -- the appliance has no bare
# `python3` on PATH at all, only kvmd's own Nix-wrapped interpreters. Any
# python helper meant to run ON the appliance (not just against a snapshot
# fetched FROM it) needs something else to find that interpreter first,
# since it can't be invoked with a plain `python3 script.py` shebang dance.
# This is that "something else" -- kept as its own tiny file rather than an
# inline SSH string so the quoting stays sane.
#
#   usage: otg-run-under-kvmd-interpreter.sh <script.py> [script args...]
set -euo pipefail

script="$1"; shift

execstart="$(systemctl cat kvmd-otg.service 2>/dev/null | sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' | head -1)"
[ -n "$execstart" ] || { echo "no ExecStart found for kvmd-otg.service" >&2; exit 2; }
[ -x "$execstart" ] || { echo "kvmd-otg.service ExecStart is not executable: $execstart" >&2; exit 2; }

wrapped="$(dirname "$execstart")/.$(basename "$execstart")-wrapped"
[ -f "$wrapped" ] || { echo "expected a Nix-wrapped sibling at $wrapped, found none" >&2; exit 2; }

interp="$(head -1 "$wrapped" | sed 's/^#!//')"
[ -x "$interp" ] || { echo "interpreter from $wrapped's shebang is not executable: $interp" >&2; exit 2; }

exec "$interp" "$script" --kvmd-bin "$execstart" "$@"
