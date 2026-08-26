# The kvmd `extras` this flake advertises in /api/info?fields=extras: kvmd's own
# extras dir MINUS the ones whose backing daemon we don't package. kvmd 4.188
# ships only `ipmi` (manifest daemon: kvmd-ipmi) and `vnc` (daemon: kvmd-vnc) —
# we run neither, so advertising them makes the dashboard query dead services
# (a DBusError on every /api/info). webterm is NOT here — it is added
# separately by kvmd-webterm, which composes it on top of this dir.
#
# HARDCODED to empty, not readDir'd off kvmd's extras dir — that was tried
# (both off kvmd's built output, then off kvmd.src's fetch) and both are a
# genuine Import-From-Derivation: `nix flake check --no-build` (CI's eval
# job) hard-refuses the implicit realization EITHER form forces — confirmed
# via two real CI runs, 2026-08-26 (see git log around this file's history:
# georgs-mac-mini found the build-output IFD; the fetch-based retry moved the
# failure to "source.drv is not valid" — same class of refusal, not just
# gated on expensive builds). A locally-cached kvmd/fetch masks this
# entirely, which is why local repros of the exact CI command passed clean
# while every real CI run — starting from a genuinely empty store — failed
# identically.
#
# kvmd 4.188's real extras/ dir contains ONLY ipmi + vnc (verified by hand
# against the v4.188 release tree), so excluding both — the old readDir-based
# filter's actual behavior today — reduces to this always-empty linkFarm.
# Losing the automatic future-proofing (a newly-packaged extra lighting up
# without touching this file) is the real, accepted tradeoff: if kvmd is
# bumped to a version that ships a NEW extra whose daemon this flake
# packages, check the new release's extras/ dir by hand and add
# `{ name = "..."; path = "${kvmd.src}/extras/..."; }` entries below
# (`kvmd` would need re-adding to this file's arguments then too).
{ linkFarm }:
linkFarm "kvmd-extras" [ ]
