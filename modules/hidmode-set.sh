# PiKVM HID-mode switch executor. Two forms:
#
#   pikvm-hidmode get         Print the next-boot mode (desktop|ipad) by
#                             classifying the boot-authoritative override —
#                             read-only, no privilege needed.
#   pikvm-hidmode set <mode>  Write the mode + re-assemble the gadget. Privileged
#                             (writes kvmd state + restarts units): run as root,
#                             either directly on-box (admin debug path) or as the
#                             templated unit pikvm-hidmode@<mode>.service that the
#                             loopback endpoint starts via a polkit start grant.
#
# `set` installs the canonical per-mode override YAML (store paths injected by
# the nix wrapper as $HIDMODE_DESKTOP_YAML / $HIDMODE_IPAD_YAML) at the mutable
# /var override kvmd reads last, then re-assembles the gadget. That override is
# the SINGLE source of the mode (#53) — there is deliberately no second marker
# file to fall out of sync with it, and the write is ATOMIC (temp + rename) so a
# crash never leaves a torn/partial override. The mode keys (mouse.absolute /
# mouse_alt.device) are gadget TOPOLOGY, so a pure /api/hid swap can't apply them
# — kvmd-otg must re-run and the UDC re-bind. Restart order: kvmd-otg first
# (teardown → rebuild the gadget, the USB re-enumerate) then kvmd (reconnect to
# the new gadget).

# The nix wrapper injects $HIDMODE_OVERRIDE_PATH (modules/runtime-paths.nix's
# hidmodeOverride channel — the canonical contract, Finding 3/Phase 2; this
# path was independently hardcoded here AND in hidmode.nix/hidmode-endpoint.nix
# before, silently driftable). No fallback: pikvm-hidmode is always built by
# the nix wrapper, never invoked standalone.
override="$HIDMODE_OVERRIDE_PATH"

cmd="${1:-}"

case "$cmd" in
    get)
        # Print the next-boot mode by classifying the boot-authoritative override
        # (the SINGLE source; #53 dropped the parallel marker). Debug read-out —
        # the endpoint's GET /hidmode classifies the same file. The override is
        # always our toJSON (compact JSON), so the mode is a stable substring of
        # the topology keys. Absent / unrecognised => "unknown" (never a guess).
        if grep -q '"absolute":[[:space:]]*false' "$override" 2>/dev/null; then
            echo ipad
        elif grep -q '"absolute":[[:space:]]*true' "$override" 2>/dev/null; then
            echo desktop
        else
            echo unknown
        fi
        ;;

    set)
        mode="${2:-}"
        case "$mode" in
            desktop) src="$HIDMODE_DESKTOP_YAML" ;;
            ipad)    src="$HIDMODE_IPAD_YAML" ;;
            *) echo "usage: pikvm-hidmode set <desktop|ipad>" >&2; exit 2 ;;
        esac
        # Atomic install (#53): write a temp in the SAME directory, then rename
        # onto the override. A same-filesystem rename is atomic, so a crash or
        # power-loss leaves the OLD or the NEW override — never a torn/truncated
        # one that would misclassify (or fail to classify) the next-boot mode.
        tmp="$(mktemp "$override.XXXXXX")"
        trap 'rm -f "$tmp"' EXIT
        install -m0644 -o kvmd -g kvmd "$src" "$tmp"
        mv -f "$tmp" "$override"
        echo "pikvm-hidmode: mode=$mode; re-assembling gadget (kvmd-otg then kvmd)" >&2
        systemctl restart kvmd-otg.service
        systemctl restart kvmd.service
        ;;

    *)
        echo "usage: pikvm-hidmode {get | set <desktop|ipad>}" >&2
        exit 2
        ;;
esac
