# `systemctl show -p DevicePolicy` never reports "closed" just because `DeviceAllow` is set

Related: [[nix-drvpath-string-context]], [[systemd-privatetmp-isolation]] —
same class of gotcha (folk wisdom about a tool's defaults vs. what it
actually does), caught the same way (a real run surfacing the discrepancy,
then checking the primary source instead of trusting the doc comment).

## The trap

It's common knowledge that adding `DeviceAllow=` entries to a systemd unit
"deny-by-default"s its device access — and that's true. It's easy to phrase
that as "setting `DeviceAllow` flips `DevicePolicy` to `closed`" and write a
test that asserts exactly that:

```python
policy = machine.succeed(
    "systemctl show my-unit.service -p DevicePolicy --value"
).strip()
assert policy == "closed", policy   # fails: reports "auto"
```

This fails even when the unit's device access genuinely is restricted (no
crash, no permission errors, everything works). `policy` comes back `"auto"`
regardless of how many `DeviceAllow=` lines the unit has.

## Why

`man systemd.resource-control`, `DevicePolicy=`:

> **auto** — in addition, allows access to all devices **if no explicit
> `DeviceAllow=` is present**. This is the default.

`DevicePolicy` is a three-value *policy setting* (`strict` / `closed` /
`auto`), not a computed/effective state. `auto` is the default whether or not
`DeviceAllow=` is set — the setting's *value* never changes on its own.
What changes is `auto`'s own *behavior*: with no `DeviceAllow=` entries,
`auto` allows (almost) everything; with `DeviceAllow=` entries present,
`auto` allows only the standard pseudo-devices plus whatever's explicitly
listed — i.e. the same deny-by-default posture `closed` describes, just
reached via `auto`'s own definition rather than by setting `DevicePolicy=
closed` explicitly. `systemctl show -p DevicePolicy` reports the *setting*,
so it stays `"auto"` unless the unit file explicitly writes
`DevicePolicy=closed` (or `strict`) itself.

## The fix

Test (or otherwise verify) the fact that's actually configured and
observable, not the property name folk wisdom expects:

```python
device_allow = machine.succeed(
    "systemctl show my-unit.service -p DeviceAllow --value"
).strip()
assert device_allow != "", "DeviceAllow is empty — no device restriction is in effect"
```

Combined with a genuine behavioral check (the unit doesn't crash-loop, no
"Permission denied" in its journal for the access it's SUPPOSED to have),
this proves the restriction is both configured and not over-restrictive —
which is what actually matters. `DevicePolicy`'s reported value was never a
meaningful signal here.

## Where this bit us

`tests/local-display.nix`'s Track-C VM test (`checks.<system>.local-display`)
asserted `DevicePolicy == "closed"` after confirming the unit survives 20s
with no crash-loop. The crash-loop-absence assertion — the one that actually
reproduces the real hardware regression (it-03400, 2026-08-24: a missing
`"char-tty rw"` `DeviceAllow` entry denied the unit's own TTYPath, crash-
looping on `Permission denied`) — passed correctly. Only the `DevicePolicy`
assertion was wrong, confirmed by an actual VM run (not by reading the man
page first — the man page confirmation came *after* the real run surfaced
the discrepancy). Fixed to assert `DeviceAllow` is non-empty instead.

## The general lesson

When a test wants to prove "this security-relevant setting had the effect I
expect," assert the *configured* fact (the setting itself, or a directly
observable consequence like a permission error occurring or not) rather than
a *derived name* you expect a tool to report differently based on that
setting. Tools frequently keep reporting the setting you wrote, not a
recomputed effective-policy label — `man`, not memory, settles which is
which.
