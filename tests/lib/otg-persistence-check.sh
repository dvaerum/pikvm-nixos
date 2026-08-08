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
#                                   [--host root@10.10.132.110]
#                                   [--deploy-ref <flake-ref>] [--no-deploy]
#
# --no-deploy runs the before/after comparison WITHOUT redeploying, which is
# how you sanity-check the harness itself: it must report "unchanged" when
# nothing happened. A persistence check that cannot first be seen agreeing
# with a no-op is not measuring what it claims.
#
# --deploy-ref names the flake to deploy (WITHOUT the #rpi4 attr; it is
# appended). Strongly preferred over the default: without it the script uses
# nixos-upgrade.service, which tracks the flake's DEFAULT BRANCH rather than
# whatever the box is running. On a box sitting on a branch that does not
# redeploy — it REVERTS, possibly to a tree that lacks the feature under test.
# Passing the ref also lets the script pre-compute the generation the deploy
# SHOULD produce, and then verify it did.
set -euo pipefail

HOST="root@10.10.132.110"
MODE=""
HW=""
DEPLOY=1
DEPLOY_REF=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
	case "$1" in
	--mode) MODE="$2"; shift 2 ;;
	--horizontal-wheel) HW="$2"; shift 2 ;;
	--host) HOST="$2"; shift 2 ;;
	--deploy-ref) DEPLOY_REF="$2"; shift 2 ;;
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

# Which generation SHOULD this deploy produce? Computed from the ref BEFORE
# deploying, so the outcome can be verified rather than the command trusted.
EXPECTED_GEN=""
if [ "$DEPLOY" -eq 1 ] && [ -n "$DEPLOY_REF" ]; then
	echo
	echo "=== EXPECTED GENERATION (pre-computed from $DEPLOY_REF) ==="
	EXPECTED_GEN="$(nix eval --refresh --raw \
		"${DEPLOY_REF}#nixosConfigurations.rpi4.config.system.build.toplevel")"
	echo "$EXPECTED_GEN"
fi

# When was the gadget last assembled? If a deploy doesn't restart kvmd-otg the
# gadget is simply whatever it already was, and comparing it to itself proves
# nothing. This timestamp turns that from an invisible false pass into a
# stated one.
otg_started_before="$(sh_remote 'systemctl show kvmd-otg -p ActiveEnterTimestamp --value')"

if [ "$DEPLOY" -eq 1 ]; then
	echo
	echo "=== REDEPLOY ==="
	if [ -n "$DEPLOY_REF" ]; then
		# Keep the output. Discarding it makes a failed deploy undiagnosable —
		# "nixos-rebuild failed" with no reason is a dead end, which this script
		# demonstrated before the log was retained.
		CACHIX_KEY="nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
		if ! sh_remote "nixos-rebuild switch --refresh --flake '${DEPLOY_REF}#rpi4' --option extra-substituters https://nixos-raspberrypi.cachix.org --option extra-trusted-public-keys '${CACHIX_KEY}'" \
			>"$WORK/deploy.log" 2>&1; then
			echo "ABORT: nixos-rebuild failed; persistence is untestable." >&2
			echo "--- last 20 lines of the deploy ---" >&2
			tail -20 "$WORK/deploy.log" >&2
			exit 1
		fi
		tail -1 "$WORK/deploy.log"
	else
		echo "NOTE using nixos-upgrade.service, which tracks the DEFAULT BRANCH."
		echo "     If the box is on a branch this REVERTS it. Prefer --deploy-ref."
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
fi

echo
echo "=== AFTER ==="
gen_after="$(sh_remote 'readlink -f /run/current-system')"
echo "generation: $gen_after"

# Did the deploy land the tree we asked for? A deploy that "succeeds" while
# producing a different generation than the ref evaluates to is the
# artifact-identity failure: exit 0, box running something else.
if [ -n "$EXPECTED_GEN" ]; then
	if [ "$gen_after" != "$EXPECTED_GEN" ]; then
		echo
		echo "FAIL: the deploy did NOT produce the tree $DEPLOY_REF evaluates to." >&2
		echo "  expected: $EXPECTED_GEN" >&2
		echo "  actual  : $gen_after" >&2
		echo "Whatever this run measured, it was not persistence across the" >&2
		echo "intended deploy. Do not read the mode comparison below as evidence." >&2
		exit 1
	fi
	echo "generation MATCHES the pre-computed expectation for $DEPLOY_REF"
fi

# THE MARKER IS WHAT A REDEPLOY ACTUALLY THREATENS — not the gadget.
# A redeploy deliberately does NOT restart kvmd-otg (the mutable mode files are
# kept out of restartTriggers), so the assembled gadget survives untouched and a
# gadget-only comparison is close to a tautology. What a redeploy COULD destroy
# is the mode marker — a tmpfiles rule reseeding it, an activation script
# rewriting it. That damage is INVISIBLE in the gadget: the mode keeps looking
# correct until the next boot, then silently flips. So check the marker itself.
marker_after="$(sh_remote 'cat /var/lib/kvmd/hidmode 2>/dev/null || echo "<absent>"')"
echo "mode marker after deploy: $marker_after"
if [ "$marker_after" != "$MODE" ]; then
	echo
	echo "FAIL: the deploy CLOBBERED the mode marker." >&2
	echo "  expected: $MODE" >&2
	echo "  actual  : $marker_after" >&2
	echo "The running gadget may still look correct — a redeploy does not" >&2
	echo "re-assemble it — so this would stay invisible until the next reboot," >&2
	echo "which is precisely when a user would hit it." >&2
	exit 1
fi
echo "marker SURVIVED the deploy (still '$MODE')"

otg_started_after="$(sh_remote 'systemctl show kvmd-otg -p ActiveEnterTimestamp --value')"
if [ "$otg_started_before" = "$otg_started_after" ]; then
	echo
	echo "NOTE kvmd-otg did NOT restart across this deploy"
	echo "     (ActiveEnterTimestamp unchanged: $otg_started_after)"
	echo "     This is the EXPECTED design — the mode files are deliberately kept"
	echo "     out of restartTriggers so an update cannot disturb a live gadget."
	echo "     What that means for this run: the gadget comparison below is close"
	echo "     to a tautology, and the load-bearing evidence is the MARKER check"
	echo "     above. Proof that the mode is correctly RE-DERIVED on a fresh"
	echo "     assembly comes from the REBOOT leg, not from this one."
else
	echo "kvmd-otg DID restart ($otg_started_before -> $otg_started_after), so the"
	echo "gadget was genuinely re-assembled and the comparison below has content."
fi

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
