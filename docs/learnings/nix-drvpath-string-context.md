# A bare `.drvPath` in a derivation attribute still forces a real build

## The trap

An "eval-only" check that wants to prove a derivation *instantiates*
cleanly — without paying to actually build it — typically reaches for
`.drvPath`:

```nix
pkgs.runCommand "my-eval-check" {
  drv = someSystem.config.system.build.toplevel.drvPath;
} "printf '%s\n' \"$drv\" > $out";
```

This looks like it should be cheap: `.drvPath` is just the store path of
the `.drv` file, and producing a `.drv` file only requires *evaluation*,
not *building*. But `nix build` on `my-eval-check` will silently plan to
build `someSystem`'s **entire closure** — kernel included, on a NixOS
system — before it can build the tiny `runCommand`.

## Why

A Nix string carries *context*: metadata tracking which store paths it
depends on. When a `.drv` path ends up (with its context intact) as a
derivation's attribute value, Nix's `derivation()` builtin treats it as a
genuine **input derivation** of the new derivation — not just text. An
input derivation reference means "build this input's default output
before running my builder," which is exactly what a `.drv`-file
reference is *for* in the normal case (it's how derivations declare their
build-time dependencies on each other's outputs). Nix has no way to tell
"I want the literal text of this path" apart from "I depend on this
derivation's output" once the context is attached — the string looks the
same either way.

So the "eval-only" check silently became a full build. On a system
(kernel, initrd, every package in the closure) this can mean hundreds of
derivations and tens of gigabytes — enough to crash a shared, memory-
constrained build host outright (confirmed: this is what happened here —
`nix build` planned 220 derivations / 19 GiB, including compiling a full
Raspberry Pi kernel from source, and the nix-daemon died under the
resulting memory pressure).

## The fix

Strip the context before it's embedded, with `builtins.unsafeDiscardStringContext`:

```nix
pkgs.runCommand "my-eval-check" {
  drv = builtins.unsafeDiscardStringContext someSystem.config.system.build.toplevel.drvPath;
} "printf '%s\n' \"$drv\" > $out";
```

This keeps the *text* of the `.drv` path (still real, still points at a
real store path once instantiated) while dropping the build dependency.
Instantiation — actually producing the `.drv` file, which is what proves
the configuration evaluates without error — still happens as a normal
side effect of forcing the string; nothing downstream needs that `.drv`'s
*output* to exist, so nothing forces it to be built.

`unsafeDiscardStringContext` is the standard, narrow idiom for exactly
this situation (see nixpkgs' own uses, e.g. printing store paths into log
messages or `passthru` metadata without pulling them into the build
graph). It doesn't change what a check verifies — the drv path text is
identical either way — it only removes an accidental build dependency.

## Where this bit us

`flake.nix`'s `checks.host-eval` and `checks.module-standalone` (see
their comments for the specific fix) — both are meant to prove
`nixosConfigurations`/`nixosModules.pikvm` *evaluate* cleanly in seconds,
without ever needing `/dev/kvm` or a real build. Confirmed via a scratch
`nix eval` that discarding the context resolves the same `.drvPath` in
seconds with zero derivations built, versus `nix build` on the
un-discarded version planning a full kernel compile.

## The general lesson

Any "prove this evaluates" check that surfaces a derivation's `.drvPath`
(or any derivation reference) through another derivation's attributes —
not just via `builtins.trace`/stderr, which never touches the build
graph — needs `unsafeDiscardStringContext` on that reference, or it isn't
eval-only. Verify a new eval-only check actually stays eval-only with a
real `nix build -L` and watch for `these N derivations will be built` —
`N` should match only the check's own tiny derivations, not the closures
it's inspecting.
