# PiKVM HID-recovery privileged host op. Run as one instance of the
# pikvm-hid-recover@<action>.service template (root); performs a single
# recovery step then exits. The instance name IS the action, matched verbatim
# to the MCP recovery contract (note the mixed separators):
#
#   soft_connect  Toggle the UDC's USB attach line (disconnect; settle; connect)
#                 WITHOUT rebuilding the gadget — the proven ~6s HID recovery.
#   udc-rebind    Re-bind the gadget to its UDC (unbind-if-bound, then bind).
#                 Deliberately NOT `kvmd-otg restart`: start re-mkdir()s the
#                 whole gadget and throws FileExistsError on an already-built
#                 one. This only rewrites the UDC link; the gadget's
#                 functions/configs are left intact.
#   reboot        Last resort: reboot the host.
#
# The UDC name is discovered at runtime (fe980000.usb on a Pi 4, dummy_udc.0
# under dummy_hcd in a VM), so nothing is board-hardcoded.

action="${1:-}"

# The nix wrapper injects $HID_RECOVER_GADGET (modules/runtime-paths.nix's
# otgGadgetName channel — the canonical contract, Finding 3/Phase 2; this
# path was independently hardcoded here AND in hidmode-endpoint.nix before,
# silently driftable). No fallback: pikvm-hid-recover is always built by the
# nix wrapper, never invoked standalone.
gadget="$HID_RECOVER_GADGET"

# The single registered UDC (there is exactly one on a PiKVM / in the test VM).
find_udc() {
    local d
    for d in /sys/class/udc/*/; do
        [ -d "$d" ] || continue
        basename "$d"
        return 0
    done
    return 1
}

# Wait up to ~10s for the UDC to enumerate on the host (state == configured).
# Under dummy_hcd the loopback host configures it too, so this is VM-checkable.
wait_configured() {
    local udc="$1" state=""
    for _ in $(seq 1 10); do
        state="$(cat "/sys/class/udc/$udc/state" 2>/dev/null || true)"
        [ "$state" = "configured" ] && return 0
        sleep 1
    done
    echo "hid-recover: UDC $udc did not reach 'configured' (last: ${state:-unknown})" >&2
    return 1
}

case "$action" in
    soft_connect)
        udc="$(find_udc)" || { echo "hid-recover: no UDC under /sys/class/udc" >&2; exit 1; }
        echo "hid-recover: soft_connect on $udc" >&2
        echo disconnect > "/sys/class/udc/$udc/soft_connect"
        sleep 2
        echo connect > "/sys/class/udc/$udc/soft_connect"
        wait_configured "$udc"
        ;;

    udc-rebind)
        udc="$(find_udc)" || { echo "hid-recover: no UDC under /sys/class/udc" >&2; exit 1; }
        [ -e "$gadget/UDC" ] || { echo "hid-recover: gadget $gadget not present" >&2; exit 1; }
        echo "hid-recover: udc-rebind $gadget -> $udc" >&2
        # Idempotent: unbind if currently bound (an empty write on an
        # already-unbound UDC errors, which we tolerate), then bind. Never
        # touches the gadget's functions/configs, so it sidesteps the kvmd-otg
        # start FileExistsError trap.
        echo "" > "$gadget/UDC" 2>/dev/null || true
        echo "$udc" > "$gadget/UDC"
        wait_configured "$udc"
        ;;

    reboot)
        echo "hid-recover: rebooting host" >&2
        systemctl reboot
        ;;

    *)
        echo "usage: pikvm-hid-recover <soft_connect|udc-rebind|reboot>" >&2
        exit 2
        ;;
esac
