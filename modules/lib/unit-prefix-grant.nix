# A least-privilege polkit grant: ONLY `triggerUser` may `systemctl start`
# units matching `unitPrefix`, nothing else. Was a byte-identical 12-line
# rule duplicated between hidmode.nix (unitPrefix = "pikvm-hidmode@") and
# hid-recovery.nix (unitPrefix = "pikvm-hid-recover@") — including the
# safety assertion, which existed on only ONE side (hid-recovery.nix) before
# this consolidation, silently driftable.
#
# Deliberately a plain function, not a NixOS submodule: it returns a config
# FRAGMENT the caller merges into its own `config`, rather than something
# imported wholesale — the caller decides how (and whether) to gate it. In
# particular, hidmode.nix's own `enable` defaults independently off
# `services.pikvm.otg.enable` (not tied to its endpoint), so hidmode.nix
# wraps the WHOLE fragment this returns (assertion included — a triggerUser
# nobody grants privilege to needs no existence check either) in its own
# `lib.mkIf cfg.endpoint.enable`, while hid-recovery.nix's `enable` is only
# ever set by its own endpoint module, so it merges this fragment straight
# into its existing `lib.mkIf cfg.enable { ... }` with no extra wrapping.
{ lib }:
{
  # Human label for the assertion message, e.g. "PiKVM HID-mode",
  # "PiKVM HID-recovery".
  feature,
  # The exact // comment text (2 lines, no leading "// ") to place above the
  # rule — kept as an explicit param rather than derived from feature/
  # unitPrefix so each caller's ORIGINAL wording is preserved byte-for-byte
  # (hidmode.nix's and hid-recovery.nix's comments differ in more than just
  # the nouns substituted, so one generic template can't reproduce both).
  comment,
  # The systemd unit-name prefix being granted, e.g. "pikvm-hidmode@",
  # "pikvm-hid-recover@". Units are matched by prefix (indexOf == 0), so
  # this should end in "@" for a template unit.
  unitPrefix,
  # The system user granted `start` on units matching unitPrefix. This
  # function only GRANTS polkit privilege — it does not create the user;
  # the caller's endpoint module is responsible for that.
  triggerUser,
  # Whether `triggerUser` is actually a declared system user right now
  # (i.e. `config.users.users ? ${triggerUser}` in the CALLER's own
  # config) — passed in rather than this function taking the whole
  # `config`, keeping it a pure, portable helper.
  triggerUserDeclared,
}:
{
  assertions = [
    {
      assertion = triggerUserDeclared;
      message = ''
        ${feature}: triggerUser = "${triggerUser}" is not a declared system
        user. This grant only GRANTS it polkit privilege — the matching
        endpoint module (or an equivalent) must actually create it. Enable
        that endpoint, or create the user yourself if you're wiring up a
        different trigger.
      '';
    }
  ];

  # polkit must actually be running for the rule (and thus a non-root
  # `systemctl start`) to work — it's off by default on a headless appliance.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    ${comment}
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("verb") == "start" &&
          subject.user == "${triggerUser}") {
        var unit = action.lookup("unit");
        if (unit && unit.indexOf("${unitPrefix}") == 0) {
          return polkit.Result.YES;
        }
      }
    });
  '';
}
