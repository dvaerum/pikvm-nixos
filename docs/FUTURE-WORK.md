# Future work

Small, deliberately-deferred items — noted here so they aren't lost, not
because they're blocking anything currently in flight. Each entry says why
it was deferred and from what piece of work it was scoped out of.

## Migrate test files onto modules/runtime-paths.nix's channels

`modules/runtime-paths.nix` (Finding 3, Phase 2) consolidated the
appliance's shared runtime-path contract (hidmode token, HID-recovery token,
HID-latch status, the hidmode override file, the OTG gadget name) into one
canonical place, after finding several of these paths independently
hardcoded across multiple *production* modules (e.g. the hidmode token path
was duplicated in three separate files before the fix).

Six **test** files still hardcode the same literal path strings directly,
rather than deriving them from `runtimePaths.*`:

- `tests/hidmode.nix`
- `tests/hidmode-web.nix`
- `tests/mcp-hid-recovery-env.nix`
- `tests/otg-mode-assembly.nix`
- `tests/hid-recovery.nix`
- `tests/kvmd-services.nix`

This was deliberately left out of Finding 3's scope: the bug Finding 3 fixes
is *silent* drift — production code hand-matching a literal that quietly
goes stale while nothing notices. A test file hardcoding the same literal
fails *loudly* the moment the real value changes (the test breaks), which is
a fundamentally different risk class — a maintainability nice-to-have, not
a correctness fix. Migrating all six would have been a genuine scope
expansion bolted onto Finding 3's actual fix.

Worth doing eventually for consistency and so a future path rename doesn't
require hunting down every test's copy by hand — but not urgent.
