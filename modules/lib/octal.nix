# Octal string <-> decimal int conversions Nix's builtins don't provide,
# plus `umaskFor`: the systemd UMask= value that makes a NEWLY-CREATED
# regular file (default creation request 0666, no execute bits) land at
# exactly the given octal mode string — so a producer derives its umask
# from the SAME runtime-paths.nix channel.mode a consumer/test checks
# against, instead of a hand-typed literal that can silently drift from it
# (e.g. hid-latch-monitor.nix's UMask="0022" vs its own channel's mode
# "0644", previously two independently-typed facts).
#
# `umaskFor` is only valid for execute-free (data-file) modes — a mode with
# any execute bit would need a different baseline (0777) creation request,
# which this helper doesn't handle; nothing in this repo currently needs
# that case.
{ lib }:
let
  octalDigit =
    c:
    let
      n = lib.toInt c;
    in
    assert lib.assertMsg (n >= 0 && n <= 7) ''octal.nix: "${c}" is not a valid octal digit (0-7)'';
    n;

  fromOctal = s: lib.foldl' (acc: c: acc * 8 + octalDigit c) 0 (lib.stringToCharacters s);

  toOctalDigits =
    n: if n < 8 then [ (toString n) ] else toOctalDigits (n / 8) ++ [ (toString (n - 8 * (n / 8))) ];

  toOctal = n: lib.fixedWidthString 4 "0" (lib.concatStrings (toOctalDigits n));
in
{
  inherit fromOctal toOctal;

  # 511 (decimal) == 0777 (octal), all nine permission bits set. For a 9-bit
  # value x, "511 - x" and "0b111111111 XOR x" (the bitwise complement) are
  # the SAME number — the top bit never borrows during the subtraction —
  # so plain arithmetic subtraction from 511 IS the 9-bit bitwise complement
  # here, with no bitwise-not builtin needed.
  umaskFor = m: toOctal (511 - fromOctal m);
}
