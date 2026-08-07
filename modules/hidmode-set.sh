# PiKVM HID-mode switch executor. Two forms:
#
#   pikvm-hidmode get         Print the current mode (desktop|ipad) from the
#                             marker file — read-only, no privilege needed.
#   pikvm-hidmode set <mode>  Write the mode + re-assemble the gadget. Privileged
#                             (writes kvmd state + restarts units): run as root,
#                             either directly on-box (admin debug path) or as the
#                             templated unit pikvm-hidmode@<mode>.service that the
#                             loopback endpoint starts via a polkit start grant.
#
# `set` installs the canonical per-mode override YAML (store paths injected by
# the nix wrapper as $HIDMODE_DESKTOP_YAML / $HIDMODE_IPAD_YAML) at the mutable
# /var override kvmd reads last, writes the marker, then re-assembles the gadget.
# The mode keys (mouse.absolute / mouse_alt.device) are gadget TOPOLOGY, so a
# pure /api/hid swap can't apply them — kvmd-otg must re-run and the UDC re-bind.
# Restart order: kvmd-otg first (teardown → rebuild the gadget, the USB
# re-enumerate) then kvmd (reconnect to the new gadget).

marker="/var/lib/kvmd/hidmode"
override="/var/lib/kvmd/hidmode.yaml"

cmd="${1:-}"

case "$cmd" in
    get)
        # Unseeded → the faithful default. Matches the tmpfiles seed.
        if [ -r "$marker" ]; then cat "$marker"; else echo "desktop"; fi
        ;;

    set)
        mode="${2:-}"
        case "$mode" in
            desktop) src="$HIDMODE_DESKTOP_YAML" ;;
            ipad)    src="$HIDMODE_IPAD_YAML" ;;
            *) echo "usage: pikvm-hidmode set <desktop|ipad>" >&2; exit 2 ;;
        esac
        install -D -m0644 -o kvmd -g kvmd "$src" "$override"
        printf '%s\n' "$mode" > "$marker"
        chown kvmd:kvmd "$marker"
        chmod 0644 "$marker"
        echo "pikvm-hidmode: mode=$mode; re-assembling gadget (kvmd-otg then kvmd)" >&2
        systemctl restart kvmd-otg.service
        systemctl restart kvmd.service
        ;;

    *)
        echo "usage: pikvm-hidmode {get | set <desktop|ipad>}" >&2
        exit 2
        ;;
esac
