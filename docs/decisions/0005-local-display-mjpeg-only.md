# 0005 — local-display: mjpeg is the only source mode, streamer.forever auto-set

Status: **Accepted** — implemented 2026-08-31.
Owner: pikvm-nixos@nixos-developer-system.
Related: `services.pikvm.localDisplay` (`modules/local-display.nix`, #52) is the
feature itself; docs/decisions/0004-local-display.md (VM testability) is the
prior ADR for this module — this one is additive, no conflict.

## Context

`task_c9df75066f71` (filed from a real live conflict on it-03400, 2026-08-31):
local-display's `mpv` and kvmd's `ustreamer` can both want `/dev/kvmd-video`,
which is single-open ("first grabber wins" — already flagged as a known
trade-off when the module shipped 2026-08-24). Two real observations:

1. No coordination existed between the two: kvmd's own `ustreamer` runner
   retries a failed start ~1s after failure (`kvmd/apps/kvmd/streamer/runner.py`'s
   `__process_task_loop`); local-display's systemd unit retries 5s after `mpv`
   exits (`Restart=always RestartSec=5`), with zero mutual signaling. Confirmed
   against kvmd 4.188's real source, not assumed — whichever side happens to
   retry first simply wins the device.
2. While tracing that, a second gap surfaced: local-display's existing
   `mjpeg` source mode (added alongside `v4l2` at ship time as the
   web-UI-friendly alternative) carried an "UNVERIFIED — relies on
   mpv-as-a-persistent-client keeping kvmd's streamer alive" caveat. Tracing
   kvmd's real idle-stop logic (`apps/kvmd/server.py`'s `__stream_controller`)
   showed this was a confirmed false hope, not merely unverified: kvmd counts
   only its OWN WebSocket `stream=1` sessions plus brief snapshot activity;
   `modules/nginx.nix` proxies `/streamer` straight to ustreamer's unix
   socket, bypassing kvmd's WS layer entirely — so kvmd is blind to a raw
   HTTP mjpeg client and will idle-stop ustreamer out from under it once its
   own WS client count hits 0, same as if nobody were watching.

georg's ruling (via manager, 2026-08-31): the appliance's core function is
the REMOTE video stream; local-display's HDMI-out mirror is secondary and
must never be able to block or starve it. Fix it for real, not with another
manually-set toggle that can be lost on a re-image (the exact class of bug
`hosts/pikvm01.nix`'s own `streamer.forever = true` override already exists
to work around, from a different incident).

## Decision

**Remove the `v4l2` source mode entirely** — `source`, `device`,
`captureResolution`, and `captureFramerate` options are gone.
`services.pikvm.localDisplay` now always reads via the shared nginx-proxied
`streamUrl` (ustreamer's own MJPEG output — the exact feed the web UI
serves), never opens `/dev/kvmd-video` directly. This makes the contention
architecturally impossible instead of arbitrated: there is no longer a code
path in this module that can compete with kvmd for the capture device, so a
future edit can't silently reintroduce the race. `DeviceAllow` narrows
accordingly — `char-drm rw` + `char-tty rw` only, no raw capture device
allowance to drop by mistake.

**`services.pikvm.kvmd.settings.kvmd.streamer.forever = lib.mkDefault true;`**
whenever `localDisplay.enable` is true (`modules/local-display.nix`'s
`config` block) — closes the mjpeg-mode gap above declaratively. `mkDefault`
so a host with its own explicit reason can still override it, same escape
hatch `hosts/pikvm01.nix` already uses for its own independent reason (no
conflict today: pikvm01 doesn't enable localDisplay).

**Trade-off accepted, not hidden**: mjpeg reads a re-encoded JPEG stream
through ustreamer + nginx rather than the raw capture device directly —
slightly more latency and CPU than the removed v4l2 path (already the
accepted `streamer.forever` cost, ~3% CPU, documented on pikvm01). This was
already the documented alternative at ship time; removing v4l2 just makes it
the only option instead of arbitrating which caller gets exclusive access.
No host currently overrides `source` (the option didn't exist long enough for
one to), so this is a zero-downstream-impact removal, not a breaking change to
any live config.

## Consequences

- `it-03400` (the one host with `localDisplay.enable = true`) needs a real
  redeploy + on-hardware confirmation that local-display renders correctly
  over mjpeg AND that the web UI stream keeps working with local-display
  running simultaneously — the exact scenario that used to be a silent
  failure. This is the real-hardware verification this ADR's change is
  gated on before being considered done, not just eval-green.
- `tests/local-display.nix`'s VM behavioural gate (2c) now asserts the
  captured argv reads the ustreamer stream URL and contains no `v4l2`
  reference; its eval-level static gate (1) additionally asserts
  `streamer.forever` reads `true` on the real it-03400 host config, so a
  future edit that drops either half of this fix fails CI, not just a live
  appliance.
- Any future source beyond mjpeg (e.g. a lower-latency path) needs a fresh
  design that keeps the "kvmd's remote stream must never be starved"
  invariant explicit, not a `source` enum re-added casually.

## Correction (2026-08-31, real-hardware round 2): stock `/streamer` needs auth

it-03400 merged + deployed the decision above and found a second, real gap
on real hardware: `https://127.0.0.1/streamer/stream` requires kvmd's admin
session/Basic auth (`curl` unauthenticated → 401; `-u admin:admin` → 200,
real MJPEG content). mpv's invocation carries no credentials — this module's
own prior "UNVERIFIED on HW" comment on the mjpeg path was, once actually
tested end-to-end, a confirmed gap, not a false alarm. Without it,
local-display never renders at all (retry-loops on stream-open instead of
the old device-contention crash) — a real regression this ADR's original
verification (VM-only, stub-argv-only) couldn't have caught, since the stub
never made an actual network request.

**Rejected fix: embed the admin credential.** Considered and dropped — kvmd
ships `admin:admin` as a changeable DEFAULT, not a fixed value; hardcoding it
(even via sops, which the manager flagged as the required mechanism for any
real secret here) creates a second, later, SILENT breakage the moment an
operator rotates their password for a real reason. A local, on-box
supervisor reading kvmd's own stream shouldn't need to track an admin
credential's lifecycle at all.

**Decision: a second, unauthenticated, loopback-only nginx location.**
`services.pikvm.web.localStreamerBypass` (`modules/nginx.nix`) adds
`/local-streamer`, proxying to the SAME `ustreamer` upstream as stock
`/streamer`, gated by `allow 127.0.0.1; allow ::1; deny all;` +
`auth_request off;` instead of kvmd's credential store. Real security, just
IP-based rather than credential-based — appropriate here because the only
caller is a systemd unit on the SAME box, not a remote client. Does not
touch stock `/streamer`'s own auth requirement at all (additive, separate
location). Auto-enabled (`mkDefault true`) whenever `localDisplay.enable` is
true, same declarative-not-manual-toggle posture as `streamer.forever`.
`local-display.nix`'s `streamUrl` default moves to
`https://127.0.0.1/local-streamer/stream`; its systemd unit now also orders
`after`/`wants` `nginx.service` (not just `kvmd.service`), and a new
`localDisplay.enable -> services.pikvm.web.enable` assertion makes the
now-real "mjpeg mode has nothing to connect to without the web front-door"
misconfiguration fail eval instead of silently retry-looping forever.

**Test gap closed too, not just the bug**: `tests/local-display.nix` now
imports `nginx.nix` (transitively, via `local-display.nix`'s own `imports`
— a real dependency now, not an ambient one) and issues a REAL `curl` of
`/local-streamer/stream` over the VM's real nginx, asserting a genuine `200`
— the specific check that would have caught this regression before it ever
reached real hardware. An argv-only assertion structurally cannot see an
auth failure; only a live request over the real route can. (One nuance hit
building this check: ustreamer's `/stream` is a genuinely infinite
`multipart/x-mixed-replace` response by design, so `curl` gets the `200`
status almost instantly but then blocks on the never-ending body until
`--max-time` kills it — curl's own exit code is a timeout even on full
success. The test asserts on the printed status code via `machine.execute`,
not on curl's exit code via `machine.succeed`.)
