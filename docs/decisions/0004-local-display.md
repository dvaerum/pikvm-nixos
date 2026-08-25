# 0004 — local-display VM testability (sysfsDrmRoot, mpv stub, DeviceAllow guard)

Status: **Accepted** — implemented 2026-08-24 (Track C, architecture-review plan).
Owner: pikvm-nixos@georgs-mac-mini (hosts/CI + this module's test surface).
Related: `services.pikvm.localDisplay` (`modules/local-display.nix`, #52) is the
feature itself; this ADR is additive — no existing ADR governs local-display, so
there's no conflict to reconcile.

## Context

`services.pikvm.localDisplay` shipped 2026-08-24 with **zero automated test
coverage** — every fact about it (DV-timings lock, 1080p30, the DeviceAllow
crash-loop) was measured by hand on real appliance silicon (it-03400). That
crash-loop is the concrete motivating incident: setting `DeviceAllow` at all
narrows systemd's *effective* device access for the whole unit to deny-by-
default (`DevicePolicy` itself keeps reporting its unset default, `auto` —
see the correction note below), which silently revoked the unit's own
implicit access to its `TTYPath=/dev/tty2` + `StandardInput=tty-force` — a
`Permission denied` crash-loop that has nothing to do with GPU presence. A NixOS
VM has no real DRM hardware, but this bug is a **systemd cgroup decision**, not
a hardware one — so a VM genuinely can reproduce it, if the module is made
testable.

The module as shipped resisted testing on two axes:

1. **Connector detection was hardwired to `/sys/class/drm`** — the supervisor's
   `connector_connected`/`first_connected` shell functions globbed that literal
   path, so a test had no way to feed it fake hotplug states without a real DRM
   card.
2. **The nix-computed parts of the supervisor script were interpolated inline**
   into one large `writeShellApplication` string — workable to read, but it
   meant the "static shape" of the unit (TTYPath, the getty conflict, the
   DeviceAllow list) and the "control-flow logic a test wants to exercise
   unmodified" were the same undifferentiated blob.

Two smaller footguns rode along:

- `TTYPath = "/dev/tty2"` and `conflicts = [ "getty@tty2.service" ]` encode the
  **same fact** (which VT the player owns) as two independently-typed literals
  — nothing stops them drifting apart on a future edit.
- The `DeviceAllow` list's "must always include `char-tty rw`" invariant lived
  only in a comment. A comment doesn't fail a build.

## Decision

**`sysfsDrmRoot`** (internal option, default `/sys/class/drm`): the supervisor's
two connector-detection functions now glob under `${cfg.sysfsDrmRoot}` instead
of a literal path. A test points it at a directory of fake
`card0-<connector>/status` files it fully controls — real hotplug, fake sysfs.
`internal = true` because it's a testing knob, not something a real deployment
should ever need to set.

**`vt`** (default `2`, replacing the two hardcoded `2`s): `TTYPath` and the
conflicting getty unit are now both *derived* from this single option
(`"/dev/tty${toString cfg.vt}"` / `"getty@tty${toString cfg.vt}.service"`) — one
fact, one place, can't drift.

**Script extraction via `builtins.readFile`**: the supervisor's control-flow
logic moved to `modules/local-display-run.sh`, a plain static shell file with
no nix `${}` interpolation inside it — same idiom already established by
`modules/hidmode-set.sh` (via `hidmode.nix`) and `modules/hid-recover.sh` (via
`hid-recovery.nix`). Every nix-computed value (`mode`, `fixed_connector`,
`drm_root`, `mpv_exe`, `player_args`, the source-specific log lines) is assigned
as a plain shell variable in a small nix-generated preamble, prepended to the
readFile'd text. This is what makes the static file trustworthy to read and
test as plain bash: nothing in it depends on nix's own string-escaping rules.

**DeviceAllow structural guard**: `mandatoryDeviceAllow = [ "char-drm rw"
"char-tty rw" ]` is now the *only* place that pair is written, kept separate
from the v4l2-conditional `${cfg.device} rw` addition — a future extra device
rule gets appended to a new list, not edited into this one. An `assertions`
entry (`lib.elem "char-tty rw" deviceAllow`) backs the separation with a real
eval failure, not just code organization, if it's ever dropped anyway.

**`mpv` package is fully swappable via the existing `package` option** — no new
option needed. A test sets `services.pikvm.localDisplay.package =
pkgs.writeShellScriptBin "mpv" 'printf "%s\n" "$@" > /tmp/argv; sleep
infinity';` and the *entire* supervisor (bash control flow, connector polling,
re-exec-on-change, and — critically — the systemd sandboxing that caused the
original crash) runs for real. Only the player binary is fake.

## Test coverage (`tests/local-display.nix`)

Two kinds of gate, deliberately kept separate:

1. **Eval-level, static** (outside `testScript`, off the already-built
   `nixosConfigurations.it-03400` — the coordination point Phase 3 already
   wired up): `assert` that `DeviceAllow` contains `"char-tty rw"`, `conflicts`
   contains the derived getty unit, and `TTYPath` agrees with it. Fails eval
   instantly, same idiom as `flake.nix`'s `host-eval`.

   **Deliberately NOT checked here:** `DevicePolicy`. Not a nix-eval-visible
   fact regardless (we never write it into the config, so there'd be nothing
   to assert on) — but see the correction below, it isn't a meaningful runtime
   fact either.

2. **VM, behavioural**: the stub `mpv` + fake `sysfsDrmRoot` let the real
   supervisor run against a fake DRM tree that starts with `HDMI-A-2`
   connected. Asserts, in order: the unit survives ~20s with `NRestarts==0` and
   no `"Permission denied"` in its journal (the actual crash-loop
   reproduction); `DeviceAllow` reads non-empty at runtime (`systemctl show`);
   the stub's captured argv contains `--drm-connector=HDMI-A-2` and the
   load-bearing `--demuxer-lavf-o=input_format=mjpeg` hint; then the fake
   cable moves (`HDMI-A-2` disconnects, `HDMI-A-1` connects) and, in `auto`
   mode, the supervisor re-renders onto `HDMI-A-1` within its poll cadence,
   with the restart count still `0` afterward.

   **Correction (2026-08-25, nixos-developer-system, on the first real VM run
   of this test):** the original version of gate 2 asserted `DevicePolicy ==
   "closed"` at runtime, on the same "DeviceAllow flips DevicePolicy to
   closed" assumption as this ADR's Context section originally stated. Both
   were wrong: per `man systemd.resource-control`, `DevicePolicy=auto` (the
   default, never overridden here) narrows its *effective* permissiveness
   once `DeviceAllow` is non-empty, but its *reported setting value* stays
   `"auto"` — it never flips to literally read `"closed"` unless a unit sets
   that explicitly. `systemctl show -p DevicePolicy` on this unit reports
   `"auto"` even while the restriction is genuinely live, confirmed
   empirically (the assertion failed on a real run while the crash-loop-
   absence check right above it passed). The test now asserts `DeviceAllow`
   is non-empty instead — the fact that's actually configured and
   meaningful. Full writeup: `docs/learnings/systemd-devicepolicy-auto.md`.
   Same run also caught a second, unrelated gap: this ADR's fixture paths
   (fake DRM status, the stub's argv-capture file) were originally under
   `/tmp`, invisible to the real unit's `PrivateTmp=true` sandboxing —
   relocated to `/run`. See
   `docs/learnings/systemd-privatetmp-isolation.md`.

**What this does NOT prove**: a VM can't demonstrate a picture actually
renders — there's no real DRM/GPU in it. That's not the bug that shipped,
though; the bug that shipped was a sandboxing crash-loop, which is exactly what
this VM *can* prove doesn't happen. No hardware gate is added by this ADR: the
feature is opt-in with zero hosts affected in practice (`hosts/it-03400.nix` is
the one host with `localDisplay.enable = true`, and it's `mode = "fixed"` by
default there — `auto` mode's on-appliance hotplug characterization remains
tracked separately per the module's own header, unaffected by this ADR).

## Consequences

- Any future edit to `modules/local-display.nix` that reintroduces the
  DeviceAllow crash-loop gets caught by CI (`checks.<system>.
  local-display`) before it ever reaches an appliance again — the exact
  regression class this ADR closes.
- `sysfsDrmRoot` being `internal = true` means it won't show up in generated
  option docs; if a real use case for a non-default DRM sysfs root ever
  surfaces, flip that to `false` rather than adding a second option.
- The script-extraction idiom (nix preamble + `builtins.readFile`'d static
  logic) is now used by three modules (`hidmode.nix`, `hid-recovery.nix`,
  `local-display.nix`) — worth reaching for by default on any future module
  whose shell logic outgrows a few lines of inline nix-interpolated text.
