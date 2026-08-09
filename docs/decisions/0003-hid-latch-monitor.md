# 0003 — HID-latch monitor as a native appliance systemd service

Status: **Accepted** — design greenlit 2026-08-09.
Owner: pikvm-nixos@nixos-developer-system (the appliance nix module + wiring).
Related: the af8d7d2 latch classifier lives in `pikvm_mcp_server` (MCP-node lane);
the existing HID-recovery apparatus is `services.pikvm.hidRecovery` +
`hid-recovery-endpoint.nix` (see [0001](0001-ipad-hid-mode.md) for the same
executor/endpoint split idiom).

## Context

A production PiKVM (pikvm01) sat **HID-dead for ~6.6 days** with **systemd green
throughout** — `kvmd` and `kvmd-otg` both `active`, `NRestarts=0`. The unit
health lied; the gadget was gone. Nothing on the box noticed, because nothing
watched the one thing that was actually broken. This is the #48 failure class
(gadget never bound / torn down) one fuse longer: **a silent, unattended HID
death that unit status cannot see.**

A detection classifier already exists and is HW-proven (merged to
`pikvm_mcp_server` main as **af8d7d2**): persistence ≥90s (fire once at sustained
un-health, reset on any healthy sample), `latched`→udc-rebind vs
`thrashing`→power_cable from a re-enum count, reboot→`unreliable` via `boot_id`.
The **classifier core is transport- and signal-agnostic**; the open question was
only *where it runs and what it samples*.

Two earlier hosting attempts were retired:

- **Per-session in the WB-kiosk MCP (stdio):** the MCP is a per-session spawn, so
  an in-process timer is **inert between sessions** — exactly zero coverage
  during the 6.6-day unattended outage that motivates this.
- **A macOS LaunchDaemon polling pikvm01 over SSH:** works, but drags in a Mac, a
  scoped SSH deploy key, sops, a forced-command wrapper, and — because a Mac
  daemon can itself die silently — an **external dead-man observer**.

**georg's ruling (2026-08-09):** *"for the pikvm-nixos you can have the
monitoring service."* The monitor becomes a **native systemd service on the
pikvm-nixos appliance**, reading its **own local UDC**. This is the cleanest
answer: `systemd` is always-on and survives reboots (no session dependency), and
the whole SSH/Mac/key/sops/external-observer apparatus **drops away** — the box
watches itself.

Scope: this covers **any box running pikvm-nixos**. pikvm01 (stock Arch) is
covered only once it runs the appliance — georg's accepted framing.

## Decision

A report-only systemd service **`pikvm-hid-latch-monitor.service`** on the
appliance runs the af8d7d2 monitor bin (shipped in `pikvm-mcp-server`) with a
**local-UDC source** replacing the SSH source. This is a **source swap under an
unchanged, HW-proven classifier core**, not a detection rewrite.

### The health signal (frozen; all three criteria it-03400-measured on real appliance silicon)

**1. Composite health — key on `function`, NOT `state` alone, NOT configfs `UDC`.**
On an uncabled appliance `/sys/class/udc/<udc>/state` is **blind to a full
teardown** — it reads `not attached` whether the gadget is bound-and-healthy or
completely gone. Measured:

| condition | configfs `…/kvmd/UDC` | `/sys/class/udc/<udc>/function` | HID nodes | `state` |
|---|---|---|---|---|
| bound + healthy | `fe980000.usb` | `kvmd` | 3 | `not attached` |
| unbound (empty write) | `` (empty) | `` (empty) | 0 | `not attached` |
| **kvmd-otg stopped (#48)** | **ENOENT (path absent)** | **`` (empty)** | **0** | `not attached` |

So the local source computes:

    healthy = (read('/sys/class/udc/<udc>/function') non-empty  ⇒ gadget BOUND)
              AND (state ∈ acceptable-set)

- `function` is the **stable field of record** — it belongs to the hardware
  controller and survives with no gadget at all, reading empty cleanly.
- configfs `/sys/kernel/config/usb_gadget/<gadget>/UDC` is **corroboration
  only**, and its **ENOENT ⇒ BROKEN (`healthy:false`), NEVER a source_error.** In
  the #48 class the gadget directory is never created, so a naive read gets
  ENOENT; classifying that as "unreachable" would report the **most-dead box as
  merely the one we can't reach** — the vacuous shape we refuse. A genuine
  source_error is `/sys` itself being unreadable.
- HID-node count (`/dev/kvmd-hid-*`, 0 ⇒ broken) is an optional third
  corroborator.
- `unbound ⇒ healthy:false` **always** — so the monitor **catches the #48
  gadget-never-bound silent-death** (the actual 6.6-day shape; `kvmd` stayed
  `is-active active` throughout it).

**2. Re-enum signal — the dwc2 gadget-side bind line.** Latched-vs-thrashing needs
a re-enumeration count. The appliance is the **gadget** side (dwc2), not the host
side; it logs, on **bind only** (unbind logs nothing):

    dwc2 fe980000.usb: bound driver configfs-gadget.kvmd

So `journalctl -k -b | grep -c 'bound driver configfs-gadget'` is a **monotonic
bind counter**: **flatline ⇒ latched** (stuck unbound), **climbing ⇒ thrashing**.
pikvm01's host-side `new device is high-speed` **never appears** on an appliance
and is dropped; the pattern is **config, not a constant**
(`PIKVM_LATCH_REENUM_PATTERN`).

**3. Boot-scoped `-b` only — the appliance has no RTC.** Pre-NTP kernel
timestamps are ~5 months stale, so `journalctl --since` **silently under-counts**
binds (measured: `-b`→5, `-b --since -2h`→4). An under-count pushes
`thrashing`→`latched` ⇒ recommends `udc-rebind` for what is actually an
**electrical fault** (wrong rung, same class as reboot-mid-window). Therefore the
bind counter is read **boot-scoped (`-b`) only — never `--since`, never a time
window**; any windowed count is a **delta between boot-scoped samples** (the
runner's job), and **onset time (`downSince`) comes from the monitor's own sample
clock, never journal timestamps.** (Same no-NTP discipline the team already holds
for pikvm01, whose clock runs ~11 months behind.) The appliance journal is
`Storage=persistent` (ring-wrap-safe intra-boot); `boot_id`→`unreliable` covers
the reboot reset.

### Interface (classifier stays signal-agnostic)

The classifier sample generalizes to a signal-agnostic
`HealthSample { t, healthy, reenumCount, bootId?, detail?, bound?, state? }`:
only `healthy` drives the up/down decision (it replaces the old
`isHealthy(state)==healthyState`); `bound`/`state`/`detail` ride along untouched
into the JSONL + status records for diagnostics. **The composite predicate lives
entirely in the local source** (`hid-latch-local-source.ts`, MCP-node lane); the
SSH source is unchanged (`healthy = state===expected`) and both feed the same
core. A `PIKVM_LATCH_SOURCE=local|ssh` selector keeps **one codebase** (georg's
intent) and leaves the af8d7d2 classifier core **untouched and HW-proven**.

### Alert channel + on-box dead-man

Report-only v1. Two surfaces, no new transport/token/port:

- **journald** — the bin's JSONL (`tick`/`alert`/`source_error`) via
  `StandardOutput=journal`: the durable, always-on, `journalctl`-queryable record.
- **The existing HID-recovery endpoint** — the runner writes
  `/run/pikvm-hid-latch/status.json` **atomically each sample**; the loopback
  `hid-recovery-endpoint` gains **`GET /hid-recovery/latch-status`** (bearer-auth,
  same as `/hid-recovery/udc-state`) returning it → the MCP **`/mcp`
  health_check** and the **443 dashboard** both read it. status.json carries
  `{ok, healthy, bound, state, detail, alert, classification,
  classificationConfidence, recommendedRung, downSince, sustainedForSec,
  reenumCount, bootId, lastSampleAt}` (no secrets → world-readable).

**The dead-man is solved on-box.** `systemd Restart=` covers a monitor **crash**;
**`lastSampleAt` freshness** covers a **hang** (a stale timestamp ⇒ the monitor
died, flagged by health_check). This is exactly the self-liveness problem the Mac
path needed an external observer for — the appliance architecture makes the
external heartbeat **moot** (retired).

### Two fault modes, labelled distinctly (do not over-claim)

- **Unbound teardown** (`function` empty / configfs ENOENT — the #48 class, the
  6.6-day shape): **fully covered, and substitution-free FIRE-validated on real
  appliance silicon** — it-03400 can manufacture it (`echo "" >
  …/usb_gadget/kvmd/UDC` is a genuine, reversible hardware teardown; HID char
  devices actually disappear and restore).
- **Target-attached `configured → not attached` (VBUS) latch**: a **second mode**,
  and its coverage is **config-dependent**. The default acceptable-state set is
  `configured,not attached` — so a *legitimate* target unplug does **not**
  false-fire — which means this mode is **not distinguished from a normal unplug
  by default.** It is detected only on a deployment that declares a target is
  *always* attached, by setting `PIKVM_LATCH_HEALTHY_STATE=configured`
  (single-state, the pikvm01/ssh semantics). Even then its **FIRE is
  cabling-gated** on an uncabled appliance (it-03400's UDC reads `not attached`
  forever; the gadget-side bind counter can't see host VBUS/attach churn) — same
  class as [#51](0001-ipad-hid-mode.md)'s behavioural gate. Label it **"opt-in
  per deployment, and not-FIRE-validated-on-uncabled-silicon,"** never "fully
  proven." The **unbound-teardown class above** is what the default appliance
  covers and it-03400 validates.

### Enablement

Default-**on** with `services.pikvm.otg.enable` — there must be a gadget/UDC to
watch. Report-only + local + cheap ⇒ safe to default on; off where there is no
gadget (e.g. `zero2w` with the MCP off).

### v2 (deferred, flagged — not v1)

Auto-recovery: on `latched` trigger `pikvm-hid-recover@udc-rebind` (the oneshot
already ships — see `services.pikvm.hidRecovery`, PR#10); `thrashing`→power_cable
is **alert-only** (no software fix). Trivial wiring given the existing units;
deliberately deferred so v1 is a pure, safe observer.

## Verification / merge gates

- **Aggregate appliance eval** — `nixosConfigurations.<appliance>.config.system.build.toplevel.drvPath`
  (full fixpoint). This ADDS a service to the host; **per-module-green ≠
  appliance-evaluates**.
- **VM test** — the service **starts**, reads the local UDC, emits
  `status.json`, and the endpoint **serves** `GET /hid-recovery/latch-status`
  (+ the composite unit-tests on the MCP side, incl. the **ENOENT⇒BROKEN** and
  **`-b`-only-counter** cases — the two silicon-caught traps).
- **it-03400 substitution-free HW-gate is the real trust boundary for the local
  path** — the new local source + service is **new code**; af8d7d2's 93.1s
  SSH-FIRES does **not** transfer to the local path by derivation identity (and
  cross-arch identity is per-nixpkgs anyway). it-03400 gates STAYS-QUIET
  (bound+not-attached, 0 alerts / 0 source_errors) + FIRES (unbind → `function`
  empty ≥90s → `latched`→udc-rebind) + rebind-clears + the negative control, on
  its real appliance.

### Gating notes (operational — for whoever re-gates the FIRES path)

- **A FIRES run needs ~160s of sustained unbind, not ~120s.** With the 60s
  baseline the monitor can spend 30–60s *detecting* before the ≥90s sustain
  clock even starts, so a hold that looks "past threshold" at 120s can still
  read healthy. Hold the unbind for ~160s minimum before concluding no-fire.
  (it-03400 twice mis-called its own too-short window — 70s, then 85.8s — as a
  non-fire; a 90.8s-sustained hold fired `latchDurationMs: 90820`.)
- **Verify the 0644 status-file mode by a direct `stat`/`ls -l` (`-rw-r--r--`),
  not by an endpoint 200.** A 200 is *consistent with* a readable file but a
  same-user read would also 200 — it does not prove the world-readable bit that
  lets the different-user endpoint traverse in. Assert the mode, not a proxy.

### Env surface (nix service → bin)

`PIKVM_LATCH_SOURCE=local`, `PIKVM_LATCH_UDC` (optional; default = the single UDC
via `ls /sys/class/udc | head -1`, matching `hid-recover.sh`'s `find_udc`),
`PIKVM_LATCH_GADGET=kvmd`, `PIKVM_LATCH_REENUM_PATTERN='bound driver configfs-gadget'`
(pattern only — the `-b`-only journalctl structure is fixed in the source so
`--since` can't be reintroduced by config), `PIKVM_LATCH_HEALTHY_STATE` (the
acceptable-state **set**, comma-separated; default `configured,not attached` so a
bound-but-unplugged appliance is healthy and a legitimate unplug doesn't
false-fire — bound-ness is the real gate. Set to a single `configured` on a
target-always-attached deployment to also detect the VBUS-latch second mode; a
bound box in a state *outside* the set, e.g. stuck `addressed`, is unhealthy),
`PIKVM_LATCH_STATUS_PATH=/run/pikvm-hid-latch/status.json`, plus the cadence /
persistence knobs already in the bin.
