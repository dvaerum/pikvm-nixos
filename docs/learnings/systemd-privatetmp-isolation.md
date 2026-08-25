# A unit with `PrivateTmp=true` doesn't see files a test writes under the host's `/tmp`

Related: [[systemd-devicepolicy-auto]], [[nix-drvpath-string-context]] — same
class of gotcha (a systemd sandboxing setting behaving less permissively than
casual intuition suggests), same discovery path (a real VM run surfacing the
discrepancy, then confirming against the actual man page).

## The trap

A NixOS VM test wants to feed a service under test some fixture files —
fake sysfs data, a captured-argv file from a stubbed binary, whatever — and
reaches for `/tmp` because it's the obvious scratch space:

```nix
systemd.tmpfiles.rules = [
  "f /tmp/fake-sysfs/some-file 0644 root root - some-content"
];
```

```python
machine.wait_for_file("/tmp/some-captured-output")
```

This hangs forever (or times out) if the unit under test has
`PrivateTmp = true` in its `serviceConfig` — which is common, reasonable
hardening for services that don't need to share `/tmp` with anything. The
unit never sees the fixture; a stub binary it launches that writes to `/tmp`
never produces anything the test script (running outside that unit's
namespace) can see either.

## Why

`PrivateTmp=true` puts the unit in a new mount namespace where `/tmp` is
bind-mounted from a fresh, initially-empty `systemd-private-*` subdirectory
— NOT the host's literal top-level `/tmp`. Pre-existing content under the
real `/tmp` (including anything `systemd-tmpfiles` or the test script wrote
there) is not part of that subdirectory, so it's invisible inside the unit's
namespace. The reverse is also true: anything the unit's own processes
(including any stub child process it launches) write to `/tmp` lands in that
private subdirectory, invisible to the test script or anything else outside
the unit.

## The fix

Put test fixtures and capture files somewhere `PrivateTmp` doesn't touch.
`/run` is the natural choice — a tmpfs, cleared at boot like `/tmp`, but not
namespaced away by `PrivateTmp` (which only isolates `/tmp` and `/var/tmp`).
Confirm the unit doesn't ALSO have some other sandboxing directive that would
hide `/run` (e.g. a custom `RootDirectory=`, `TemporaryFileSystem=/run`, or
`InaccessiblePaths=/run`) before assuming it's safe — for the common case
(just `PrivateTmp=true` plus the usual `NoNewPrivileges`/`Protect*=`
hardening knobs) it's unaffected.

## Where this bit us

`tests/local-display.nix`'s Track-C VM test used `/tmp/fake-drm` for a fake
DRM connector-status tree and `/tmp/argv` for a stub `mpv`'s captured
arguments, to exercise `services.pikvm.localDisplay`'s supervisor loop
without real hardware. The real unit
(`modules/local-display.nix`) sets `PrivateTmp = true`. Confirmed via a real
VM run: the supervisor sat in "no target output; waiting for hotplug"
forever — it could never see the fixture's `status` files — and the
downstream `machine.wait_for_file("/tmp/argv")` timed out at 900s, since the
stub `mpv` (a child of the sandboxed unit) never got to run in the first
place. Not a production bug — real deploys point `sysfsDrmRoot` at `/sys`,
which `PrivateTmp` never touches — purely a test-fixture design gap. Fixed
by moving both fixture paths to `/run`.

## The general lesson

When a NixOS VM test needs to share files with a unit under test, check that
unit's sandboxing directives (`PrivateTmp=`, `ProtectSystem=`, `ProtectHome=`,
`TemporaryFileSystem=`, `InaccessiblePaths=`, etc.) BEFORE picking a fixture
path — the same sandboxing that makes the unit safer in production can make
a naively-written test hang silently, with no error beyond a generic
timeout. `/run` is usually the safe default for test-only scratch data
precisely because it's rarely namespaced away on its own.
