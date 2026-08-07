#!/usr/bin/env bash
# Real-hardware half of the #51 PERSISTENCE gate: does a selected OTG mouse
# mode survive a REDEPLOY?
#
# The reboot leg is covered in CI (tests/otg-mode-assembly.nix). A redeploy is
# not: it needs a real flake update against a real machine, which a VM test
# cannot do. This script is that leg, and it runs on the appliance.
#
# WHY REDEPLOY IS THE HARDER CASE: a reboot re-runs the same generation, so a
# mode baked into that generation trivially returns. A redeploy SWAPS the
# generation. Anything the mode depends on that lives outside the new closure
# — a hand-written runtime file, a stale unit that no longer gets restarted,
# state the module forgot to carry — disappears exactly here and nowhere else.
# This is the #49 failure with a longer fuse.
#
# The check is a strict before/after on ASSEMBLED ground truth, not on config
# files: same mode asserted green on both sides, and the gadget shape byte-for
# -byte identical across the deploy.
#
# Read-only apart from the deploy itself, which is the standard self-update
# path the appliance already runs on a timer.
#
#   usage: otg-persistence-check.sh --mode <name> --horizontal-wheel <true|false>
#                                   [--host root@10.10.132.110] [--no-deploy]
#
# --no-deploy runs the before/after comparison WITHOUT redeploying, which is
# how you sanity-check the harness itself: it must report "unchanged" when
# nothing happened. A persistence check that cannot first be seen agreeing
# with a no-op is not measuring what it claims.
set -euo pipefail

HOST="root@10.10.132.110"
MODE=""
HW=""
DEPLOY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
	case "$1" in
	--mode) MODE="$2"; shift 2 ;;
	--horizontal-wheel) HW="$2"; shift 2 ;;
	--host) HOST="$2"; shift 2 ;;
	--no-deploy) DEPLOY=0; shift ;;
	*) echo "unknown argument: $1" >&2; exit 64 ;;
	esac
done
[ -n "$MODE" ] && [ -n "$HW" ] || { echo "need --mode and --horizontal-wheel" >&2; exit 64; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SSH_CMD lets the caller supply its own transport (sshpass, a jump host, a
# different key) instead of this script hardcoding an auth scheme.
SSH_CMD="${SSH_CMD:-ssh}"

# shellcheck disable=SC2029,SC2086  # remote-side expansion and word-splitting
# of SSH_CMD are both intended.
sh_remote() {
	$SSH_CMD -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"$HOST" "$1" </dev/null
}

# The snapshot script travels as a base64 ARGUMENT, not on stdin. Piping it in
# looks tidier but consumes the ssh session's stdin, and the next invocation
# then blocks forever waiting for input that never arrives — which is exactly
# how this hung the first time it ran.
snapshot_to() {
	local payload
	payload="$(base64 -w0 <"$HERE/otg-gadget-snapshot.sh")"
	sh_remote "echo $payload | base64 -d | bash -s" >"$1"
}

assert_mode() {
	python3 "$HERE/otg_assert_mode.py" \
		--snapshot "$1" --specs "$HERE/otg-mode-specs.json" \
		--mode "$MODE" --horizontal-wheel "$HW"
}

echo "=== BEFORE ==="
gen_before="$(sh_remote 'readlink -f /run/current-system')"
echo "generation: $gen_before"
snapshot_to "$WORK/before.json"
if ! assert_mode "$WORK/before.json"; then
	echo
	echo "ABORT: the mode is not correctly assembled BEFORE the deploy." >&2
	echo "There is no point measuring whether a broken state survives; fix" >&2
	echo "the assembly first, then re-run. (Reporting this as a persistence" >&2
	echo "failure would misattribute the fault.)" >&2
	exit 1
fi

if [ "$DEPLOY" -eq 1 ]; then
	echo
	echo "=== REDEPLOY ==="
	sh_remote 'systemctl restart --no-block nixos-upgrade.service'
	# Poll to completion rather than sleeping a guessed interval.
	for _ in $(seq 1 120); do
		state="$(sh_remote 'systemctl show nixos-upgrade -p ActiveState --value' || echo unknown)"
		[ "$state" = "activating" ] || [ "$state" = "reloading" ] || break
		sleep 5
	done
	result="$(sh_remote 'systemctl show nixos-upgrade -p Result --value')"
	echo "nixos-upgrade Result=$result"
	if [ "$result" != "success" ]; then
		echo "ABORT: the deploy itself failed; persistence is untestable." >&2
		exit 1
	fi
fi

echo
echo "=== AFTER ==="
gen_after="$(sh_remote 'readlink -f /run/current-system')"
echo "generation: $gen_after"
if [ "$gen_before" = "$gen_after" ]; then
	# Not an error: a no-op deploy is the normal result when main has not
	# moved. But say so plainly — a generation that never changed makes this
	# a WEAKER test than it looks, and silently reporting "survived a
	# redeploy" would overstate the evidence.
	echo "NOTE generation UNCHANGED — nothing was actually swapped, so this run"
	echo "     does not demonstrate survival across a real generation change."
	VERDICT_QUALIFIER=" (weak: no generation change occurred)"
else
	VERDICT_QUALIFIER=""
fi

snapshot_to "$WORK/after.json"
assert_mode "$WORK/after.json" || {
	echo
	echo "PERSISTENCE FAIL: the mode did NOT survive the redeploy." >&2
	echo "  before: $gen_before" >&2
	echo "  after : $gen_after" >&2
	exit 1
}

# Strict identity, not merely "both pass". Two snapshots can each satisfy the
# spec while still differing in a field the spec does not pin — and a mode
# that quietly changes shape across a deploy is exactly the thing we are
# hunting, so we diff the whole thing.
if ! diff -u <(python3 -m json.tool "$WORK/before.json") \
	<(python3 -m json.tool "$WORK/after.json") >"$WORK/diff.txt"; then
	echo
	echo "PERSISTENCE FAIL: the assembled gadget CHANGED across the deploy," >&2
	echo "even though both sides satisfy the mode spec:" >&2
	cat "$WORK/diff.txt" >&2
	exit 1
fi

echo
echo "PERSISTENCE PASS${VERDICT_QUALIFIER} — mode '$MODE' assembled identically before and after."
echo "  NOT a behavioural claim: this says the gadget is assembled as specified,"
echo "  never that input reaches a host."
