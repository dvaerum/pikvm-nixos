# 0002 — Dashboard web control for the HID-mode switch (#51)

Status: **Accepted** — design greenlit 2026-08-07.
Owner: pikvm-nixos@georgs-mac-mini (nginx front-door + integration).
Follows: [0001 — Runtime iPad/desktop HID mode switch](0001-ipad-hid-mode.md).

## Context

ADR 0001 gives the appliance three intended control surfaces for the runtime
HID-mode switch — **API**, **UI**, **MCP** — over one authoritative
`/var/lib/kvmd/hidmode.yaml` override (the single source of the mode; #53 removed
the old parallel marker). The switch mechanism (the override + `90-hidmode.yaml`
symlink + the `pikvm-hidmode@` executor) and the **API/MCP** surface (the
loopback token endpoint, `modules/hidmode-endpoint.nix`) landed with 0001. This
ADR adds the **UI** surface.

The endpoint is deliberately **loopback-only** (`127.0.0.1:8083`) and
**bearer-token** authenticated (`PIKVM_HIDMODE_TOKEN`, read from
`/run/pikvm-hidmode/token`), mirroring `hid-recovery-endpoint`. That shape is
right for the MCP (a local process that holds the token in its env) but a browser
**cannot** reach `127.0.0.1:8083`, and — non-negotiably — **must never be handed
the token**. So a dashboard control needs a front-door bridge, and that bridge is
the security-sensitive part this ADR exists to record.

## Decision

Add `services.pikvm.web.hidModeControl` (default on when both
`services.pikvm.web.enable` and `services.pikvm.kvmd.hidMode.endpoint.enable` are
— absent on a stock-like install with no endpoint, faithful). It adds two
locations to the existing 443 vhost and one boot-time unit; it changes no
existing route.

### 1. Authenticated reverse-proxy — `location = /hidmode`

```
browser --(443, dashboard session)--> nginx --(loopback + server-side bearer)--> 127.0.0.1:8083 /hidmode
```

Four properties, each load-bearing:

- **Auth before proxy, same as the whole UI.** The stock
  `kvmd.ctx-server.conf` sets `auth_request /auth_check` at **server** level, so
  every location — including this one — is behind the dashboard session by
  default (we do **not** set `auth_request off`). There is no anonymous path to
  a switch that re-plugs the target's USB and drops the session. Auth is
  evaluated *before* the token is ever injected.
- **Token server-side only, never in the store, never to the browser.** A
  boot-time oneshot (`pikvm-hidmode-proxy-auth`) reads the endpoint's own runtime
  token (`/run/pikvm-hidmode/token`) and writes
  `/run/pikvm-hidmode-proxy/authheader.conf` = `proxy_set_header Authorization
  "Bearer …";` at `0640 root:nginx`. The value lives only in `/run`; it is never
  a `/nix/store` literal and is never present in a response body or header sent
  downstream.
- **Client cannot smuggle or read a token.** The location sets
  `proxy_set_header Authorization ""` as the base, then `include`s the generated
  file (last-wins), so the upstream Authorization is either the real bearer or
  empty — **never** whatever the client sent.
- **Fail-safe, not fail-open.** The include is a **glob**
  (`include …/*.conf`): if the oneshot hasn't run (boot ordering) the match is
  empty, nginx still starts, and the location proxies with an **empty** bearer →
  the endpoint returns `401`. A missing bearer degrades to "switch refused,"
  never to "switch open." (nginx starts *after* the oneshot in the happy path;
  the glob only guards the failure path — and deliberately does not take the
  whole 443 dashboard down with it.)

### 2. Self-contained control page — `location = /hidmode-control`

`modules/hidmode-control.html`, served behind the same dashboard auth
(`error_page 401/403 = @login`, like `location /`). Dependency-free JS that:

- `GET /hidmode` on load → shows current mode. The endpoint (post-#41) reports the
  **assembled** gadget: `{mode(=observed), requested, observed, settled}`, not just
  the requested config.
- On the toggle: a **confirm dialog** warning the switch re-plugs the target's
  USB and drops the session (~5 s, the same as a kvmd restart);
- then `POST /hidmode {"mode": …}` — **non-blocking** — with honest in-flight
  state ("switching, wait…"), no locking;
- then **polls `GET /hidmode` until `observed` reflects the new mode** — it never
  optimistically claims success before the appliance confirms. The assembled gadget
  is the single source of truth; the UI follows it.
- **Drift surfacing — the next-boot hazard, not "the switch failed":** `mode ==
  observed`, so the page is already correct about the present and offers the button
  that reconciles a half-failed switch — a user just clicks again. The subtler
  hazard is that the **persisted override (`requested`) drives the next boot**: when
  `requested != observed` the box runs one mode now but is primed to boot the other, and
  someone who reads the current mode and later reboots for an unrelated reason gets
  a silently different target. So on `settled && requested != observed` the page
  warns **which mode the box will boot into** ("saved mode is X … will boot into X
  on the next reboot"), not a raw-field dump; and it notes the re-assembling state
  (`settled == false`). This mirrors the MCP-side `pikvm_hidmode_status.driftDetected`
  (both target the same durable-intent-vs-live-gadget disagreement). The 443 proxy
  passes the body verbatim so these fields reach the browser (HW-confirmed,
  it-03400); a VM check asserts both the fields-through-proxy and the page logic.
  (Spec sharpened by the manager + it-03400 from real-silicon drift testing.)

## The functional/faithful split — control "a" is NOT the end state

This ADR ships control **"a"**: a standalone authenticated page. It is the
**functional** control + the secure proxy, landed now.

**Control "b" — integrating the toggle into the stock PiKVM dashboard menu (the
web-terminal restoration is the precedent and the bar) — is a REQUIRED
faithfulness follow-up, not optional.** A user expects the mode control where the
rest of the dashboard lives; the project's faithfulness line is firm. "a" exists
so the function and the security-critical proxy are available and reviewed
independently of the more invasive dashboard-asset composition "b" needs. **"a"
being good enough is explicitly rejected as the end state.** Tracked as #51's UI
follow-up.

## Verification & its limit

- VM (`tests/hidmode-web.nix`): unauthenticated `/hidmode` and `/hidmode-control`
  are refused (no anonymous switch path); an authenticated request reaches the
  endpoint **through the server-side bearer** (proving the injection, not a
  client-supplied token); `nginx -t` passes; the control page is served. Real
  aarch64 + browser confirmation on it-03400.
- This surface inherits 0001's hard limit unchanged: the appliance switch ships
  **assembly-verified and never behaviourally proven** — a UI that drives the
  switch does not make the target's iPad move a pointer; that remains the iPad
  rig's gate behind the cabling dependency. The control page is honest about what
  it confirms (the appliance's assembled gadget), and claims nothing about the target.
