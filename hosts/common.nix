# Settings shared by every PiKVM device: flakes, SSH, base users, and the
# self-updating behaviour. Host-specific files layer board/platform details
# on top.
{ lib, pkgs, ... }:
{
  # Flakes are required for the self-referencing auto-upgrade to work.
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Devices are storage-constrained; keep the store lean.
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Weekly self-update from this repository (see modules/system/auto-upgrade.nix).
  services.pikvm.autoUpgrade.enable = lib.mkDefault true;

  # Headless remote management.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault false;
  };

  users.users.pikvm = {
    isNormalUser = true;
    description = "PiKVM administrator";
    extraGroups = [ "wheel" ];
    # Replace with real keys per deployment (or override in a host file).
    openssh.authorizedKeys.keys = lib.mkDefault [ ];
  };
  # Allow wheel to sudo without password so the update service and admin can
  # operate on a headless appliance.
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # No ZFS on a Pi appliance — it only bloats the image and initrd.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Sensible appliance defaults.
  time.timeZone = lib.mkDefault "UTC";
  console.keyMap = lib.mkDefault "us";

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
  ];

  system.stateVersion = lib.mkDefault "26.05";
}
