#!/usr/bin/env bash
# Snapshot the ASSEMBLED USB OTG gadget as canonical JSON — ground truth.
#
# Why this exists: a config flag saying "iPad mode" proves only that something
# was written to a file. What the target actually sees is the gadget the kernel
# assembled: which HID functions exist, what descriptor each one carries, and
# which /dev nodes came out the other side. Those are the only facts a host can
# act on, so those are what we assert against. This is the #49 lesson
# (deployed != live) applied to the OTG path.
#
# Pure read. No writes, no systemctl, no module load. Safe to run at any time,
# on the appliance or inside a VM test.
#
# Output is stable and sorted so two snapshots can be diffed or hashed.
#
# Usage:  otg-gadget-snapshot.sh [gadget-name]      (default: kvmd)
set -euo pipefail

GADGET="${1:-kvmd}"
CFG="/sys/kernel/config/usb_gadget/${GADGET}"

# Reads a sysfs/configfs attr, or "" when absent. Never fails the script: an
# absent attr is a FINDING to report, not a crash that hides the rest.
attr() { [ -r "$1" ] && tr -d '\n' <"$1" || printf ''; }

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [ ! -d "$CFG" ]; then
	# Emit valid JSON even in the failure case, so the assertion engine can
	# report "no gadget" as a normal RED rather than dying on a parse error.
	printf '{"gadget":"%s","present":false,"functions":[],"hid_nodes":[],"udc":"","udc_state":""}\n' \
		"$(json_str "$GADGET")"
	exit 0
fi

udc="$(attr "$CFG/UDC")"
udc_state=""
if [ -n "$udc" ] && [ -r "/sys/class/udc/$udc/state" ]; then
	udc_state="$(attr "/sys/class/udc/$udc/state")"
fi

# --- functions -------------------------------------------------------------
# We enumerate what the CONFIGURATION LINKS, not what sits in functions/.
#
# This distinction is the whole ballgame and cost me a wrong result before a
# negative control caught it: functions/ is a POOL of available functions,
# while configs/c.N/ holds symlinks to the ones actually assembled into the
# gadget. Unlink a function and it vanishes from the host's view while its
# directory — and every attribute in it — stays behind, fully readable. A
# check that reads the pool therefore reports a removed mouse as still
# present. That is exactly the half-applied state this gate exists to catch,
# so reading the pool would have made the gate blind to its own purpose.
#
# The pool is still captured below, separately, because "in the pool but not
# linked" is a useful diagnosis rather than noise.
#
# NOTE report_desc reads short: configfs reports a page-sized st_size but
# returns only the bytes actually set, so we hash what we read, not the file
# size.
funcs_json=""
for link in $(find "$CFG"/configs/*/ -maxdepth 1 -mindepth 1 -type l 2>/dev/null | sort); do
	name="$(basename "$link")"
	case "$name" in
	hid.*) ;;
	*) continue ;;
	esac
	# Resolve the link to the function dir holding the attributes.
	d="$(readlink -f "$link")"
	[ -d "$d" ] || continue

	desc_sha=""
	desc_len=0
	if [ -r "$d/report_desc" ]; then
		# Hash the bytes as read, with no hex round-trip: fewer moving parts,
		# and it drops a dependency on xxd, which is absent from a bare NixOS
		# VM (the CI runner) even though it is present on the appliance. A
		# harness that only runs in one of the two places is not a standing
		# gate. desc_len comes from a byte count of the same read, so the
		# length and the hash can never describe different data.
		desc_sha="$(sha256sum <"$d/report_desc" | cut -d' ' -f1)"
		desc_len="$(wc -c <"$d/report_desc" | tr -d ' ')"
	fi

	entry=$(printf '{"name":"%s","protocol":"%s","subclass":"%s","report_length":"%s","desc_len":%d,"desc_sha256":"%s"}' \
		"$(json_str "$name")" \
		"$(json_str "$(attr "$d/protocol")")" \
		"$(json_str "$(attr "$d/subclass")")" \
		"$(json_str "$(attr "$d/report_length")")" \
		"$desc_len" \
		"$(json_str "$desc_sha")")

	funcs_json="${funcs_json:+$funcs_json,}$entry"
done

# --- /dev nodes ------------------------------------------------------------
# The udev symlinks kvmd's HID plugin actually opens. A function can exist in
# configfs while its /dev node is missing (udev rule not applied, wrong hidg
# index) — that combination is invisible to a configfs-only check and is
# exactly the sort of half-applied state this gate must catch.
nodes_json=""
for n in $(find /dev -maxdepth 1 -name 'kvmd-hid-*' 2>/dev/null | sort); do
	nodes_json="${nodes_json:+$nodes_json,}\"$(json_str "$(basename "$n")")\""
done

# --- unlinked pool ---------------------------------------------------------
# hid.* functions that exist in functions/ but are NOT linked into any config.
# Never asserted on; carried purely so a failure report can say "the alt mouse
# was built but never attached to the configuration" instead of the far less
# useful "the alt mouse is missing".
pool_json=""
for d in $(find "$CFG/functions" -maxdepth 1 -mindepth 1 -type d -name 'hid.*' 2>/dev/null | sort); do
	name="$(basename "$d")"
	if ! find "$CFG"/configs/*/ -maxdepth 1 -name "$name" -type l 2>/dev/null | grep -q .; then
		pool_json="${pool_json:+$pool_json,}\"$(json_str "$name")\""
	fi
done

printf '{"gadget":"%s","present":true,"udc":"%s","udc_state":"%s","functions":[%s],"hid_nodes":[%s],"unlinked_functions":[%s]}\n' \
	"$(json_str "$GADGET")" \
	"$(json_str "$udc")" \
	"$(json_str "$udc_state")" \
	"$funcs_json" \
	"$nodes_json" \
	"$pool_json"
