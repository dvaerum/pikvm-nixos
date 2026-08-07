#!/usr/bin/env python3
"""Assert an OTG gadget snapshot matches the mode that was selected.

Consumes the JSON from otg-gadget-snapshot.sh and compares it against the
expected gadget shape for a named mode. Exit 0 = PASS, 1 = FAIL,
2 = NOT-VERIFIED (see below).

THE POINT: a mode flag is a claim; the assembled gadget is the fact. This
compares the fact to the claim and goes RED when they disagree — including
when the mode "applied" without changing anything (the #49 deployed!=live
failure, which a flag-reading check cannot see).

THREE OUTCOMES, NOT TWO
Most of the value here is the third one. If a mode has no expectations
recorded yet, this exits 2 NOT-VERIFIED — it does NOT pass. A check that is
green because it never actually compared anything is worse than no check: it
launders an unknown into a reassurance. Every gate I have been burned by
failed this way ("0 errors" from hooks that never fired), so the engine is
built to make that outcome impossible to reach silently.

EXPECTATIONS ARE PER (mode, horizontal_wheel)
The wheel setting changes the descriptor bytes and report_length, so the same
logical mode has different ground truth on different rigs — the appliance runs
horizontal_wheel=true, pikvm01 runs false. A spec that ignored this would go
red on a correct box. Expectations are therefore keyed by both.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PASS, FAIL, NOT_VERIFIED = 0, 1, 2


def load_specs(path: Path) -> dict:
    with path.open() as fh:
        return json.load(fh)


def spec_key(mode: str, horizontal_wheel: bool) -> str:
    return f"{mode}/hw={'true' if horizontal_wheel else 'false'}"


def check(snapshot: dict, spec: dict, key: str) -> tuple[int, list[str]]:
    """Compare one snapshot against one expectation set.

    Returns (exit_code, lines). Collects ALL mismatches rather than stopping
    at the first: when a mode half-applies you want the whole picture, not a
    single symptom that sends you down one branch.
    """
    problems: list[str] = []
    notes: list[str] = []

    if not snapshot.get("present"):
        return FAIL, [f"RED  no gadget at all — configfs dir for "
                      f"'{snapshot.get('gadget')}' is absent"]

    # --- functions ---------------------------------------------------------
    got_funcs = {f["name"]: f for f in snapshot.get("functions", [])}
    want_funcs = {f["name"]: f for f in spec.get("functions", [])}

    missing = sorted(set(want_funcs) - set(got_funcs))
    extra = sorted(set(got_funcs) - set(want_funcs))

    unlinked = set(snapshot.get("unlinked_functions", []))
    for name in missing:
        if name in unlinked:
            # Distinguish the two ways a function goes missing. "Built but
            # never linked into the configuration" points at the assembly
            # step; "absent entirely" points at the build. Same symptom to a
            # host, very different bug to chase.
            problems.append(
                f"RED  function {name} exists in functions/ but is NOT LINKED into any "
                f"configuration — built, never assembled, invisible to the host"
            )
        else:
            problems.append(f"RED  function {name} expected by mode but ABSENT from the gadget")
    for name in extra:
        g = got_funcs[name]
        problems.append(
            f"RED  function {name} present but NOT expected in this mode "
            f"(protocol={g['protocol']} subclass={g['subclass']} "
            f"report_length={g['report_length']} sha={g['desc_sha256'][:8]})"
        )

    for name in sorted(set(want_funcs) & set(got_funcs)):
        want, got = want_funcs[name], got_funcs[name]
        for field in ("protocol", "subclass", "report_length", "desc_sha256"):
            if field not in want:
                continue
            if str(want[field]) != str(got.get(field, "")):
                problems.append(
                    f"RED  {name}.{field}: expected {want[field]!r}, "
                    f"gadget has {got.get(field)!r}"
                )
        notes.append(
            f"     {name}: protocol={got['protocol']} subclass={got['subclass']} "
            f"report_length={got['report_length']} "
            f"desc_len={got['desc_len']} sha={got['desc_sha256'][:12]}"
        )

    # --- /dev nodes --------------------------------------------------------
    # Checked separately from functions on purpose: a function can exist in
    # configfs while its /dev node never appears (udev rule mismatch, wrong
    # hidg index). kvmd opens the NODE, so a configfs-only check would call
    # that state green while the daemon cannot talk to the gadget at all.
    if "hid_nodes" in spec:
        got_nodes = sorted(snapshot.get("hid_nodes", []))
        want_nodes = sorted(spec["hid_nodes"])
        if got_nodes != want_nodes:
            problems.append(
                f"RED  /dev/kvmd-hid-* mismatch: expected {want_nodes}, got {got_nodes}"
            )

    # --- UDC binding -------------------------------------------------------
    # Binding is required in every mode. Attachment is NOT asserted: whether a
    # host is on the other end is a property of the cable, not of the mode we
    # just selected. Conflating them would make this gate un-passable on a rig
    # with no host attached, which is precisely this appliance.
    if spec.get("require_udc_bound", True):
        if not snapshot.get("udc"):
            problems.append("RED  gadget is not bound to any UDC (configfs UDC attr empty)")

    notes.append(f"     udc={snapshot.get('udc')!r} state={snapshot.get('udc_state')!r} "
                 f"(state is NOT asserted — cable property, not mode property)")

    if problems:
        return FAIL, [f"FAIL mode '{key}'"] + problems + ["  observed:"] + notes
    return PASS, [f"PASS mode '{key}' — gadget assembled as the mode claims"] + notes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--snapshot", required=True, type=Path,
                    help="JSON from otg-gadget-snapshot.sh ('-' for stdin)")
    ap.add_argument("--specs", required=True, type=Path,
                    help="mode expectation table (JSON)")
    ap.add_argument("--mode", required=True, help="mode that was selected")
    ap.add_argument("--horizontal-wheel", choices=("true", "false"), required=True,
                    help="the rig's horizontal_wheel setting — changes ground truth")
    args = ap.parse_args()

    raw = sys.stdin.read() if str(args.snapshot) == "-" else args.snapshot.read_text()
    snapshot = json.loads(raw)
    specs = load_specs(args.specs)

    key = spec_key(args.mode, args.horizontal_wheel == "true")
    entry = specs.get("modes", {}).get(key)

    if entry is None:
        print(f"NOT-VERIFIED  no expectations recorded for mode '{key}'.")
        print("  This is deliberately NOT a pass. Nothing was compared, so nothing")
        print("  is known. Add the expected function set to the spec table before")
        print("  treating this mode as gated.")
        print(f"  Modes that DO have expectations: "
              f"{sorted(specs.get('modes', {})) or '(none yet)'}")
        return NOT_VERIFIED

    if entry.get("placeholder"):
        print(f"NOT-VERIFIED  mode '{key}' is a PLACEHOLDER awaiting real expectations.")
        print(f"  reason: {entry.get('placeholder')}")
        print("  Refusing to report green on values nobody has confirmed.")
        return NOT_VERIFIED

    code, lines = check(snapshot, entry, key)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
