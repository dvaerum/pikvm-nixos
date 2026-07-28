# Faithful-PiKVM plan — default-on, like stock, plus MCP

> **Directive (user, 2026-07-28):** *"By default it's supposed to be the SAME as
> PiKVM, just with pikvm_mcp_server included and it being NixOS."* So the DEFAULT
> must behave like stock PiKVM out of the box (web UI + 443 + official auth),
> with the `/mcp` endpoint built in — and **options to harden/disable** each
> piece (the forkable-override story). This inverts today's minimal/hardened
> base + opt-in model.

## Where we already are (good news)

Grounding this in the repo changed the picture — much is already packaged:

- **Web UI assets are already bundled.** `pkgs/kvmd` copies `share/kvmd/web`
  (the PiKVM dashboard) into the kvmd package — we just don't *serve* it yet.
- **Stock kvmd auth is already seeded.** `modules/kvmd.nix` tmpfiles-copies the
  stock `/etc/kvmd/htpasswd` (**admin/admin**) on first boot, managed via
  `kvmd-htpasswd`. So the kvmd web/API credential default is already faithful.
- **MJPEG video is packaged.** `pkgs/ustreamer` + `ustreamer-python` are wired
  into kvmd's streamer config.
- **The 443 machinery exists.** `modules/nginx.nix` already does a self-signed
  443 vhost (reverse-proxying kvmd `/api` + `/mcp`).

So Phase 2 is **wiring, not a from-scratch port**, and the only genuinely hard,
multi-session piece is Janus/WebRTC (Phase 3).

## Confirmed stock defaults (docs.pikvm.org/auth)

- **OS / SSH:** `root` / `root`, SSH password-auth on. (Two separate accounts.)
- **kvmd web/API:** `admin` / `admin`, in `/etc/kvmd/htpasswd`.
- Handbook says: **change BOTH** on a new device.

## The three gaps vs stock

1. **System login** — we ship no root password + `PasswordAuthentication=false`
   → headless lockout (deviation).
2. **443 / web** — off by default (only SSH exposed).
3. **Graphical dashboard** — assets packaged but not served; no WebRTC video.

---

## Phase 1 — Auth defaults (LOW effort) — *in progress*

Make the box log-in-able the stock way, all **overridable**:

- **kvmd web/API `admin`/`admin`** — already seeded; verify only. ✓
- **OS/SSH `root`/`root` + password auth** — set in `hosts/common.nix` as
  `mkDefault`: `users.users.root.initialPassword = "root"`,
  `services.openssh.settings.PasswordAuthentication = true`, `PermitRootLogin =
  "yes"`. The current hardened no-auth becomes an explicit opt-in (override the
  mkDefaults + add keys).
- First-boot note (like stock): **change both passwords.**

**Effort LOW / Risk LOW** (security posture is intentional-per-directive; it's
exactly stock's known-default-password model). Also fixes the live first-boot
lockout — supersedes the per-key SSH pre-seed.

## Phase 2 — 443 by default + the dashboard + MJPEG + MCP (MEDIUM) — *prep*

The "works like stock" headline:

- **Decouple nginx from `mcpProxy.enable`** → the self-signed 443 vhost becomes a
  **base service** (default-on, option to disable), serving:
  - `/` → the static web UI (`share/kvmd/web`)
  - `/api` → kvmd (unix socket)
  - `/streamer` → ustreamer **MJPEG** video
  - `/mcp` → the MCP endpoint (built-in)
  - opens firewall 443
- **MCP built-in by default**, its own kvmd creds **defaulting to `admin`/`admin`**
  (the seeded htpasswd) → **no mandatory `passwordFile` secret** for the default;
  `passwordFile` becomes an optional hardening override. Removes the go-live
  secret friction.

**Effort MEDIUM / Risk LOW-MED.** Result: `https://<pi>/` is the real PiKVM
dashboard with MJPEG video + working keyboard/mouse/ATX/MSD via `/api`, plus
`/mcp`. Don't merge until the user confirms the go; the nginx-wiring branch can
start now.

> ⚠️ **Security to state to the user:** default-on = anyone who reaches 443 with
> `admin`/`admin` can drive the KVM *and* the AI agent over `/mcp`. That is
> stock PiKVM's posture extended to `/mcp` — faithful per the directive.
> Hardening (all options): change the htpasswd, set a real MCP `passwordFile`,
> restrict/disable `/mcp`, disable 443, keys-only SSH.

## Phase 3 — WebRTC / H.264 via Janus (HIGH, multi-session) — *DEFERRED*

Not ported: the Janus gateway + PiKVM's `ustreamer-janus` H.264 plugin +
`kvmd-janus` service + Pi VideoCore hardware H.264 + WebRTC signaling. This is
the low-latency premium video path. **MJPEG (Phase 2) is the functional
fallback** — the dashboard works without it, at higher bandwidth/latency.

**Effort HIGH / Risk HIGH** (packaging Janus + the PiKVM plugin + HW-H.264 on
the Pi is the least-certain piece). Deferred; note as future work.

## Phase 4 — forkable-override (cross-cutting, LOW)

Applied within every phase: `common.nix` keeps the faithful stock defaults;
every hardening (keys-only SSH, 443-off, MCP-off, real MCP secret) is an
explicit option. Downstream forks harden by overriding the `mkDefault`s.

## PR #17 reframe

The held `enable-mcp-rpi4` PR (#17) was an rpi4-scoped **opt-in** enablement with
a `passwordFile` stub. Under default-on it's **superseded** — the
mcpProxy + pikvm-mcp + hidRecovery enablement folds into the **default**
(common.nix / appliance) with `admin`/`admin` creds, no secret, all boards. So
**close PR #17** and rebuild the enablement as default-on in the Phase-2 PR.

## Sequence

1. **Phase 1** (auth defaults) — now; fixes the lockout.
2. **Phase 2** (443 + dashboard + MJPEG + MCP default-on) — prep the branch, merge
   on the user's go.
3. **Phase 3** (Janus/WebRTC) — deferred; MJPEG covers video meanwhile.

## Lanes

- **@georgs-mac-mini (this node):** nginx/hosts/443, install-sd/disko, the
  auth-default + MCP-default wiring, docs, PRs.
- **@nixos-developer-system:** the packaging half — kvmd-UI serving details,
  the ustreamer MJPEG path, and (Phase 3) Janus + HW-H.264. Serialize heavy
  aarch64 builds on the shared host.
