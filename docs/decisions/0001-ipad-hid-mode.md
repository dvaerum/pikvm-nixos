# 0001 — Runtime iPad/desktop HID mode switch (#51)

Status: **Accepted** — design v1 greenlit 2026-08-07.
Owner: pikvm-nixos@nixos-developer-system (implementation).

## Context

PiKVM emulates a USB mouse to the target machine. Two gadget shapes matter:

- **desktop** (stock / faithful default): an **absolute** primary mouse plus a
  **relative** secondary (`mouse_alt`) — two HID gadget functions. Absolute
  positioning is what a normal desktop/laptop target wants.
- **iPad**: iPadOS ignores an absolute-pointer USB HID (it treats absolute as a
  touch digitiser) and only tracks a **single relative "boot mouse."** The
  known-working shape — taken from **pikvm01**, the production kiosk — is a
  single relative mouse: `mouse.absolute=false`, `mouse_alt.device=""` (no
  second mouse), `horizontal_wheel=false`.

The repo previously shipped `services.pikvm.kvmd.ipadCompat.enable`, a
**build-time** toggle that (a) `overrideAttrs`-patched
`kvmd/apps/otg/hid/mouse.py` to flip the **absolute** maker's USB interface
fields (`protocol` 0→2 / `subclass` 0→1), and (b) applied an override bundling
the HID keys **together with** streamer tuning.

A cross-node investigation (2026-08-07) proved the `mouse.py` patch is **dead
code**: extracted from pikvm01's own pacman-tracked pre-edit `.pyc` vs its live
source, the entire hand-edit was those two lines in `_make_absolute_hid`. Under
the iPad config kvmd-otg builds a **single relative** mouse, so
`make_mouse_hid(absolute=False)` never reaches `_make_absolute_hid` — the edited
function is never executed. pikvm01's live `hid.usb1` is byte-identical to stock
`_make_relative_hid(hw=false)`. **iPad support is entirely the runtime CONFIG
(single relative mouse), not any code patch.**

We want both shapes **selectable at runtime** on one appliance — no
reinstall/rebuild — persisting across reboot **and** redeploy, with the
appliance as the single source of truth for "current mode."

## How kvmd consumes the relevant config (verified against kvmd 4.188 source)

- **Config layering** (`kvmd/apps/__init__.py` `_init_config`): `main` →
  `override.d/*.yaml` (filenames `sorted()`, **later wins**, recursive
  deep-merge, symlinks honoured, no extension filter) → `override.yaml` → test.
  This repo seeds `override.yaml` empty and routes all config through
  `override.d` (`00-nixos-paths`, `10-settings`).
- **Gadget topology** (`kvmd/apps/otg/__init__.py`): kvmd-otg always adds one
  mouse (`absolute = hid.mouse.absolute`), and adds a **second** (`mouse_alt`,
  forced to the opposite mode) **only if `hid.mouse_alt.device` is truthy**
  (`if_empty=""` in the scheme disables it). Changing `mouse.absolute` or the
  presence of `mouse_alt.device` rewrites configfs functions — it is a
  **gadget-assembly change** requiring kvmd-otg re-run + UDC re-bind. The
  runtime `/api/hid/set_params?mouse_output=…` only swaps **already-assembled**
  endpoints; it **cannot** convert single↔dual. So a config change + service
  restart is the only mechanism.
- **"Current mode" is not a clean kvmd-native field.** `GET /api/hid` exposes
  `result.hid.mouse.outputs.{active,available}`, but `available` is **empty**
  and `active` is `""` in single-mouse (iPad) mode. It reflects assembled
  topology, not our desktop/iPad abstraction. The endpoint instead classifies the
  **assembled gadget** directly (configfs descriptor-sha — see the API section and
  "Reported mode = the assembled gadget" below) as the authoritative current-mode;
  the persisted next-boot mode is classified from the boot-authoritative override
  (#53), not a separate marker.

## Decision

Introduce `services.pikvm.kvmd.hidMode` — a **runtime** desktop↔iPad switch.
Declarative nix sets the **default + base config only**; a mutable `/var` file
holds the current mode, read **last** by kvmd's config layering; one control
writes it and restarts the gadget.

### Mechanism

1. **Mutable state (persists in `/var`).**
   - `/var/lib/kvmd/hidmode.yaml` (`kvmd:kvmd`) — the override kvmd reads,
     regenerated on each switch from the canonical per-mode document. This is the
     **single** persisted source of the mode (#53): it is both what kvmd-otg
     assembles from on boot AND what `requested` is classified from — there is no
     separate marker file that could drift from it. The switch rewrites it
     **atomically** (write a temp in the same dir, then `mv` — a same-filesystem
     rename, so a crash/power-loss leaves the OLD or NEW override, never a torn
     one). NOT what the API reports as *current* — that is the assembled gadget
     (see "Reported mode = the assembled gadget" below).
2. **Read-last override.** `/etc/kvmd/override.d/90-hidmode.yaml` is a
   **generation-managed** `environment.etc` symlink → `/var/lib/kvmd/hidmode.yaml`
   (NOT a tmpfiles symlink — this is what lets it vanish on rollback; see
   "Rollback safety" below). `90-` sorts after
   `00`/`10`, so the mode wins over user `settings`; `override.yaml` stays empty
   so nothing beats it. kvmd's loader honours symlinks and ignores the
   extension, confirmed in source.
   - **desktop** doc: `{kvmd.hid.mouse.absolute=true,
     mouse_alt.device="/dev/kvmd-hid-mouse-alt"}` (explicit so the mode is
     authoritative; `horizontal_wheel` left at its default `true`).
   - **ipad** doc: `{kvmd.hid.mouse.absolute=false, horizontal_wheel=false,
     mouse_alt.device=""}`.
3. **Write-and-restart control** (clones the hid-recovery two-module idiom — no
   sudo/setuid). A `pikvm-hidmode` executor (`writeShellApplication`) validates
   the mode, installs the canonical YAML **atomically** (temp + rename, `kvmd:kvmd`),
   then restarts **kvmd-otg** (teardown → rebuild gadget = the USB re-enumerate)
   **then** kvmd. It runs as root via a templated oneshot
   `pikvm-hidmode@%i.service`. A polkit rule lets **only** the endpoint user
   `start` **only** `pikvm-hidmode@` units.
4. **Local CLI.** The same executor is on-box as `pikvm-hidmode {get,set <mode>}`
   — the debug path when the endpoint itself is broken.
5. **API + MCP** (separate `pikvm-hidmode-endpoint.nix`, clones
   `hid-recovery-endpoint.nix`): loopback token server.
   - `GET /hidmode` → classifies the **assembled gadget** (see "Reported mode =
     the assembled gadget" below) → `{"ok":true, "mode": "desktop"|"ipad"|null,
     "requested": <next-boot, classified from the override yaml>, "observed":
     <assembled>, "settled": <bool>}`. `mode`
     = the assembled gadget (the ground truth the MCP follows), `null` while
     mid-reassembly/unrecognised. This is the first-class current-mode field the
     MCP reads (appliance = single source of truth). The MCP **fail-closes** when
     the endpoint is unreachable OR `settled` is false — it never falls back to a
     declared target (a second copy of the mode is exactly #51's defect). Note an
     ABSENT endpoint (stock, no `PIKVM_HIDMODE_URL`) ≠ unreachable: with the
     feature absent the MCP uses its declared target and never refuses.
   - `POST /hidmode {"mode":"ipad"}` → token-auth → `systemctl start
     pikvm-hidmode@ipad` → `{"ok":true,"message":"mode switching, wait ~Ns; USB
     re-enumerates, active session drops"}` (honest, non-locking).
   - Wires `PIKVM_HIDMODE_URL` + the token into the pikvm-mcp env, same as
     `PIKVM_HID_RECOVERY_URL`.
6. **Persistence without clobber.** tmpfiles **`C`** (not `C+`) seeds the override
   YAML to the declarative **default** (`hidMode.default`, default `desktop`)
   **once** on fresh install; redeploy/reboot leaves `/var` untouched, so the
   runtime choice persists. The mutable file is **not** in
   `kvmdConfigTriggers`, so `nixos-rebuild switch` never restarts kvmd for a mode
   change and never resets the mode. `hidMode.default` is therefore a
   **first-boot** default only; there is deliberately no `hidMode.force` flag
   (add it only if a "rebuild forces mode" need is proven).

### Reported mode = the assembled gadget, not the requested config

`GET /hidmode` reports what the USB device ACTUALLY IS, not what was asked for.
The override yaml (`requested`) is written by `pikvm-hidmode` **before** kvmd-otg
reassembles, so between "override written" and "gadget reassembled" — or after a
failed/partial switch — the config is ahead of the live gadget. Reporting it as
*current* would make the MCP resolver drive the wrong mode: relative emits into an
absolute gadget is a silent no-op on the iPad, and the click path can report a tap
it never landed. The MCP's
fail-closed logic guards *unreachable*, not *authoritatively wrong*. This is the
#49 "deployed ≠ live" class one level deeper, and it was measured live on pikvm01
(kvmd-otg unrestarted since boot while `override.yaml` was newer — the assembled
gadget predated the config file).

So the endpoint **classifies the assembled gadget** from configfs: the mouse HID
functions LINKED into the active config (`configs/*/hid.*`, **not** the
`functions/` pool — the pool keeps removed functions readable and would report a
removed mouse as present) by report_descriptor **sha256** (+ mouse count). One
relative mouse and no absolute ⇒ `ipad`; one absolute (primary) + one relative
(mouse_alt) ⇒ `desktop`; anything else — absent gadget, mid-reassembly, or an
unrecognised descriptor ⇒ `null` (settling), never a stale/wrong mode. The
discriminator is the descriptor sha (it-03400's gate classifier, re-derived on
4.188) — deliberately **not** proto/subclass (the stock relative maker already
reads 2/1) and **not** a report_length constant. The override yaml is the
persisted source and rides along as `requested`, classified from it — the
boot-authoritative next-boot mode, torn-write-proof (#53). `requested != observed`
after settling is a drift signal nothing previously detected: the box runs one
mode now but will boot into the other. (`requested` is `null` for an
unrecognised/absent override — fail-closed, so the drift diagnostic simply doesn't
fire on a garbage config rather than guessing.)

**Consumer contract** (so the field names don't invite the wrong read): drive on
`mode`/`observed` — the authoritative assembled mode (`"desktop"|"ipad"`, or
`null`/unrecognised while settling). `settled` means the gadget is
**recognisable**, NOT that the *requested* switch succeeded: a switch that hasn't
taken effect yet (or failed) returns `ok:true, settled:true` with `requested !=
observed`. So detect a next-boot-pending / failed switch by comparing `requested`
(the yaml = what boots next) vs `observed` after settling — never by gating on
`{ok, settled}`. A consumer that only ever drives the currently-assembled `mode`
(fail-closed on `null`) is correct by construction.

### Why the switch restarts kvmd-otg then kvmd (not "just write the file")

The mode keys are gadget topology, so writing `hidmode.yaml` alone changes
nothing until kvmd-otg re-runs; the ordering (kvmd-otg first to re-assemble the
gadget, then kvmd to reconnect) is what makes the switch take effect. A **live**
instance of the failure this prevents, on pikvm01 right now: its `kvmd-otg` has
not restarted since boot (2025-09-04), but `override.yaml` was last edited
2025-09-07 — so the **running gadget was assembled from an earlier config than
the one on disk.** It is harmless there only by luck (the only delta since is a
`forever: true` streamer line that doesn't touch HID, which is why the two
read-methods above still agree). But structurally it is #49 all over again: an
edit to pikvm01's HID block would **not reach the assembled gadget until kvmd-otg
restarts, and nothing on that box enforces it.** The executor closes exactly this
gap — the write and the re-assembly are one operation, so the persisted mode and
the assembled gadget never drift apart. That is why "just write the config file"
is insufficient.

### Rollback safety: persisted mode is inert without its controller

**The hazard:** state that outlives the code governing it is the #49 family. A
naïve persist design (a tmpfiles symlink, which creates but never declaratively
removes) would survive a rollback to a **pre-#51 generation** — leaving the mode
override live and applied while the control surface (`pikvm-hidmode@` units + the
endpoint) is gone. That is *worse* than the config-reporting bug above, because
the **detector got rolled back too**: the MCP's static `--target` can then
silently disagree with the stranded gadget mode (relative-into-absolute no-op,
click path reporting positions it never hit), with no `/hidmode` left to
contradict it. The right property is that a rollback **reverts to stock** (our
faithfulness rule) — persisted mode must be **inert without its controller**.

**The fix (why point 2 uses `environment.etc`, not tmpfiles):** the read-last
`90-hidmode.yaml` symlink is **generation-managed**. It is in every #51
generation's `/etc` closure, so the mode still persists across #51→#51
**upgrades**; but NixOS etc-activation removes entries not in the current
generation, so a rollback to a pre-#51 generation **drops the symlink**, the
override stops applying, and the box reverts to stock. The `/var` content persists
but is simply no longer read. (VM-verified: the `environment.etc` symlink resolves
through `/etc/static` to the `/var` target and kvmd reads it, switch and all;
it-03400 confirms the revert-to-stock on real silicon.)

**Timing caveat:** dropping the `/etc` symlink reverts the config **intent**
immediately, but the assembled **gadget** only reverts on the next `kvmd-otg`
restart — and `kvmd-otg` is deliberately NOT in `restartTriggers` (#49:
re-assembling under live kvmd invalidates HID), so a rollback's
`switch-to-configuration` will not re-assemble it. Until then the gadget retains
the prior mode while the config no longer describes it (a self-healing-on-next-boot
window, not instant). So the rollback HW check reads the descriptor sha **twice**:
(3) immediately after rollback — may still show the old mode (the live window);
(5) after a reboot — should be stock; still the old mode at (5) means the trap
survives reboot and this fix is insufficient. Also inspect
`/var/lib/kvmd/hidmode.yaml` at (5): still present + gadget desktop = confirmation
the content is inert once unlinked. Recovery if ever stranded: a `kvmd-otg`
restart / reboot (re-assemble from the now-stock config), or re-deploy #51.

**HW positive control (it-03400, real Pi4B):** a single-variable A/B on the same
box — set ipad → roll back to a pre-#51 generation → **reboot** → read the
assembled descriptor. On the *interim tmpfiles* design the trap **survives the
reboot**: the pre-#51 generation actively **re-derives iPad** from the leftover
`/etc`→`/var` override every boot (usb1 `55c045b2`, rlen 4, 2 functions, no
mouse-alt), with no operator recovery. On the *`environment.etc`* fix the same
sequence yields **stock desktop** by the next boot (usb1 `3a71a5a2`, rlen 7, 3
functions, mouse-alt back) — the symlink is already gone immediately
post-rollback (the live window above) and the reboot produces stock. Regression
re-checked on the fixed build: a plain `set ipad → reboot` (no rollback) still
lands ipad, so making the symlink generation-managed did **not** cost
mode-survives-a-reboot. The trap is closed without losing persistence.

**Residue (intentional, documented so it isn't discovered by surprise):** only
the `/etc` symlink is generation-managed; the `/var/lib/kvmd/hidmode.yaml` override
**persists** across the rollback. So rolling **forward** again (re-deploying a
#51 generation) restores the control surface **and re-applies the persisted
mode** — the box returns to its pre-rollback mode (e.g. ipad), **not** stock.
That is deliberate (the mode is preserved across the excursion, matching the
across-upgrade persistence property); it only means "rollback reverts to stock"
describes the *rolled-back* generation, and a subsequent roll-forward is a
mode-restoring, not a mode-clearing, event.

### Option surface

- `services.pikvm.kvmd.hidMode.enable` — the runtime switch apparatus. Default
  `= services.pikvm.otg.enable` (the switch is only meaningful with the OTG
  gadget).
- `services.pikvm.kvmd.hidMode.default` — `"desktop"` | `"ipad"`, default
  `"desktop"` (fresh-install faithful default). First-boot seed only.
- `services.pikvm.kvmd.hidMode.endpoint.{enable,port,tokenFile}` — default
  `enable = services.pikvm-mcp.enable` (mirrors the hid-recovery endpoint).

### Precedence & the silent-override guard

Mode (`90`) intentionally wins over user `settings` (`10`) — a toggle a stray
setting can silently defeat is not a toggle. To avoid the inverse silent
failure, an eval-time `lib.warnIf` fires when the user's `settings` touches any
of `hid.mouse.absolute` / `hid.mouse.horizontal_wheel` / `hid.mouse_alt.device`,
naming `hidMode` as the owner of those keys.

### Retiring ipadCompat

`services.pikvm.kvmd.ipadCompat.enable` and the internal `ipadSettings`/`05-ipad`
override are removed via **`mkRemovedOptionModule`** pointing at `hidMode` — a
**loud eval failure with a pointer**, never a silent deletion. This matters more
than usual: the removed option's `mouse.py` patch is proven **dead code**, so
someone may believe it was doing something. The eval error names `hidMode` as
the replacement and states the patch was inert.

### Streamer tuning (orthogonal, documented not optioned)

The known-good iPad streamer values are **not** part of `hidMode` and get **no
new option**. Apply them via `services.pikvm.kvmd.settings` if wanted:

```nix
services.pikvm.kvmd.settings.kvmd.streamer = {
  resolution = "1280x720";          # match iPad HDMI 16:9, lowest bandwidth
  desired_fps = 30;                 # smoother than 60 over USB 2.0
  cmd_append = [ "--buffers=1" ];   # lower capture latency
};
```

## The hw=false choice — deliberately chosen, not tested (honest framing)

iPad mode forces `horizontal_wheel=false`. This **reproduces a
deliberately-chosen known-good shape; it is not a tested necessity.** Two facts,
kept distinct:

- **It is deliberate.** pikvm01 (the production kiosk) was read two independent
  ways that agree: `kvmd --dump-config` reports `hid.mouse = {absolute: false,
  horizontal_wheel: false}`, `mouse_alt.device = ""`; and its assembled gadget is
  a single mouse — `hid.usb1` `report_length=4`, descriptor `sha256 55c045b2…`,
  no mouse-alt node. Stock kvmd defaults `horizontal_wheel` to **true**
  (`plugins/hid/otg/__init__.py`), so `false` was typed against a `true` default,
  and the untouched sibling `mouse_alt.horizontal_wheel` still reads the stock
  `true`. Only the primary mouse was flipped, on purpose.
- **It is not tested.** No A/B exists anywhere showing `hw=true` fails on an
  iPad. **EXPLICIT ≠ TESTED.** #51's contract is "make the deliberately-chosen
  known-good iPad shape selectable" — we copy pikvm01's config; we do **not**
  claim `hw=true` was shown to break anything.

If that question ever actually needs deciding, the iPad rig can settle it with a
flip + click bench on pikvm01 — but that re-enumerates georg's live kiosk, so it
happens only on his explicit OK and only if needed. We do not design around
needing it. The gate table (`tests/lib/otg-mode-specs.json`) holds both
`ipad/hw=false` (active) and `ipad/hw=true` (contingent), keyed by wheel, so
flipping the decision is a one-line change with no gate rework.

## Verification & its limit (MUST NOT be glossed)

Four permanent gates: **assembly** + **persistence** (it-03400, real aarch64),
**coupling** (MCP node), **UI + behavioural** (georgs-mac-mini / iPad rig). The
gate discriminator per HID function is the **descriptor `sha256`** (carries
`horizontal_wheel` implicitly) + the **`mouse_alt` gadget-count** (1 desktop-dual
/ 0 iPad-single), with `report_length` corroborating **per-arm** (never a global
`4`-vs-`6` constant — it tracks the wheel: `{4:rel/hw0, 5:rel/hw1, 6:abs/hw0,
7:abs/hw1}`) and `protocol`/`subclass` asserted **per-function-per-mode**, never
as a standalone "2/1 ⇒ iPad" oracle (the stock relative maker already reads 2/1).

The four expected `sha256` pins are derived from kvmd 4.188 source; one arm
(`rel/hw0` `55c045b2…`) is additionally HW-confirmed on pikvm01. Note pikvm01
runs a **different** kvmd (a python3.13 tree) than the appliance's 4.188, so that
match is currently strong evidence that descriptor generation is stable across
those versions — **not yet a proven invariant.** it-03400 is recomputing all four
from the appliance's own 4.188 into `otg-mode-specs.json`; treat the pins as
version-specific until that lands.

**This feature ships assembly-verified and NEVER behaviourally proven on the
appliance.** No node on this team can currently demonstrate that appliance iPad
mode makes a real iPad move a pointer: it-03400's appliance gadget binds but the
host never enumerates it (`/sys/class/udc/*/state = not attached` — a cabling
issue on the host side), and the iPad rig's ground truth is **pikvm01**, which
runs stock Arch and is **not** our appliance. Closing that gap is a cabling
dependency tracked separately. Until then, a green assembly gate proves the
gadget re-assembles to the correct shape — **not** that anything clicks.
