# The "prove this composes/evaluates, without building it" idiom this flake's
# checks need repeatedly — collapses what used to be three independently
# hand-fixed copies (checks.host-eval, checks.appliance-standalone,
# checks.module-standalone all hit the SAME missing-unsafeDiscardStringContext
# bug separately, on three different nights).
#
# THE MECHANISM (why this needs a helper at all, not just `.drvPath`): a bare
# `.drvPath` — or worse, a derivation itself — embedded in another
# derivation's attributes still carries Nix string CONTEXT pointing at that
# .drv. Nix treats an in-context .drv reference as a real inputDrv, which
# means BUILDING that input's default output before the outer derivation can
# even run its builder. A check meant to be "eval-only, seconds" silently
# becomes "realize the whole referenced closure" — confirmed repeatedly via
# real `nix build -L` runs: hundreds of derivations, tens of GiB, sometimes a
# full aarch64 kernel cross-build under QEMU emulation. Discarding the
# context keeps the STRING (the literal path text — still useful, still real
# once instantiated) while dropping the build dependency; nothing downstream
# needs the referenced derivation BUILT, only its .drv text visible. Full
# writeup + how this was found (3 separate incidents in one night) in
# docs/learnings/nix-drvpath-string-context.md — read that before touching
# this file.
{ lib }:
{
  # `sys` is anything shaped like a `lib.nixosSystem { ... }` result (has
  # `.config.system.build.toplevel`). Returns the context-discarded drvPath
  # string: safe to embed in another derivation's attrs without forcing a
  # build of `sys`'s closure.
  evalDrvPathOf = sys: builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath;

  # Bundle N already-discarded drvPath strings into one tiny derivation that
  # just prints them — the shape every "prove these evaluate" check in this
  # flake reduces to. `pkgs` is passed explicitly (not captured) so this stays
  # usable from any per-system `let` without import-time coupling.
  mkEvalGate =
    {
      pkgs,
      name,
      drvPaths,
    }:
    pkgs.runCommand name {
      drvs = lib.concatStringsSep "\n" drvPaths;
    } "printf '%s\\n' \"$drvs\" > $out";

  # For NEGATIVE controls (proving a check's failure-detection actually
  # works, not just that its happy path evaluates): true iff evaluating
  # `expr` throws. Callers combine with `lib.assertMsg` for a descriptive
  # failure message — see checks.module-standalone for the canonical
  # pattern this generalizes (the check whose absence let the original bug
  # ship: a positive-only check risks passing for the wrong reason).
  mustNotEval = expr: !(builtins.tryEval expr).success;
}
