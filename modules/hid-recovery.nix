# PiKVM HID-recovery — the privileged HOST OPS half of the feature.
#
# When a target machine stops seeing the emulated keyboard/mouse, the fix is a
# USB-gadget nudge on the PiKVM host. This module exposes those privileged ops
# as a templated root oneshot, one instance per action (the instance name IS
# the action string from the MCP recovery contract):
#
#   pikvm-hid-recover@soft_connect.service   ~6s UDC soft_connect toggle (primary)
#   pikvm-hid-recover@udc-rebind.service     idempotent gadget↔UDC re-bind
#   pikvm-hid-recover@reboot.service         host reboot (last resort)
#
# The AUTH half — an authenticated loopback endpoint that receives the MCP
# server's request and runs `systemctl start pikvm-hid-recover@<action>` — is a
# separate module (services.pikvm.hidRecovery.endpoint, MCP-trigger side). The
# boundary: privilege lives in these root units; authentication lives in that
# endpoint. A polkit rule lets ONLY the endpoint's user start ONLY these units,
# so there is no sudo/setuid and no way to run anything else privileged.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.hidRecovery;

  mkUnitPrefixGrant = import ./lib/unit-prefix-grant.nix { inherit lib; };

  recover = pkgs.writeShellApplication {
    name = "pikvm-hid-recover";
    runtimeInputs = [
      pkgs.coreutils
      config.systemd.package # systemctl (reboot action)
    ];
    text = ''
      HID_RECOVER_GADGET=/sys/kernel/config/usb_gadget/${config.services.pikvm.runtimePaths.otgGadgetName}
    ''
    + builtins.readFile ./hid-recover.sh;
  };
in
{
  # runtime-paths.nix: this module reads it — see module-list.nix / Round-2
  # Phase 2 for why every module now imports its own declarers directly
  # instead of relying on the aggregate.
  imports = [ ./runtime-paths.nix ];

  options.services.pikvm.hidRecovery = {
    enable = lib.mkEnableOption ''
      the PiKVM HID-recovery privileged host ops (the pikvm-hid-recover@<action>
      units + the polkit grant). Pair with the recovery endpoint that triggers
      them'';

    package = lib.mkOption {
      type = lib.types.package;
      default = recover;
      defaultText = lib.literalExpression "the pikvm-hid-recover executor";
      readOnly = true;
      description = "The privileged recovery executor run by the pikvm-hid-recover@ template.";
    };

    triggerUser = lib.mkOption {
      type = lib.types.str;
      default = "pikvm-hid-recovery";
      description = ''
        The system user granted (via polkit) permission to
        `systemctl start pikvm-hid-recover@<action>.service` — and nothing else.
        This is the loopback recovery endpoint's dedicated user; it holds the
        authentication boundary while privilege stays in the root units here.
        The endpoint module is responsible for actually creating this user.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkUnitPrefixGrant {
      feature = "PiKVM HID-recovery";
      comment = ''
        // PiKVM HID-recovery: allow the loopback recovery endpoint's user to
        // start (only) the recovery action units.'';
      unitPrefix = "pikvm-hid-recover@";
      triggerUser = cfg.triggerUser;
      # This module GRANTS privilege to triggerUser but doesn't CREATE that
      # user itself — the endpoint module owns that (see triggerUser's
      # description). If triggerUser is overridden without a matching
      # endpoint (or the endpoint module isn't imported at all), the polkit
      # rule would silently reference a nonexistent user — `systemctl start`
      # from that user only ever fails at runtime with a confusing polkit
      # denial, never at eval. Catch it here instead.
      triggerUserDeclared = config.users.users ? ${cfg.triggerUser};
    })
    {
      # Templated root oneshot: one privileged recovery action per instance.
      # The instance (%i) is the action string, passed straight to the executor.
      systemd.services."pikvm-hid-recover@" = {
        description = "PiKVM HID recovery: %i";
        serviceConfig = {
          Type = "oneshot";
          # %i is soft_connect | udc-rebind | reboot — validated by the executor.
          ExecStart = "${cfg.package}/bin/pikvm-hid-recover %i";
          # Runs as root: writes /sys/class/udc/*/soft_connect and the gadget's
          # configfs UDC link, and (reboot) signals PID1. Intentionally NOT
          # hardened with ProtectKernelTunables/ProtectControlGroups — those make
          # /sys read-only and would break the soft_connect / UDC-bind writes.
        };
      };
    }
  ]);
}
