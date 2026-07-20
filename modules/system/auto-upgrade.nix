# Self-referencing weekly auto-upgrade.
#
# Deployed PiKVM devices track *this* flake on GitHub and rebuild themselves
# on a weekly timer, so pushing to the repo's main branch rolls out to every
# device on its next cycle. Because the update is a full NixOS switch from a
# pinned flake, a bad push can be rolled back and every generation stays in
# the bootloader.
{ config, lib, ... }:
let
  cfg = config.services.pikvm.autoUpgrade;
in
{
  options.services.pikvm.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Weekly self-update from the pikvm-nixos flake on GitHub.";
    };

    flake = lib.mkOption {
      type = lib.types.str;
      default = "github:dvaerum/pikvm-nixos#${config.networking.hostName}";
      defaultText = lib.literalExpression ''"github:dvaerum/pikvm-nixos#''${config.networking.hostName}"'';
      description = ''
        Flake reference the device rebuilds itself from. Defaults to this
        repository's configuration matching the machine's hostname.
      '';
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "systemd OnCalendar expression for the upgrade timer.";
    };

    allowReboot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the device may reboot automatically after an upgrade that
        changed the kernel/initrd/boot. Off by default so a KVM never drops
        mid-session; new boot entries still take effect on the next reboot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake dates allowReboot;
      # --refresh so the GitHub flake ref is re-resolved each run instead of
      # being served from a stale eval cache.
      flags = [ "--refresh" ];
      randomizedDelaySec = "45min";
    };
  };
}
