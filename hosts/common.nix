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

  # Faithful stock-PiKVM remote access: OS login is root/root over SSH with
  # password auth, exactly like stock PiKVM (https://docs.pikvm.org/auth/). All
  # `mkDefault`, so a hardened deployment overrides them (set
  # PasswordAuthentication = false + add authorizedKeys + drop the root password).
  # ⚠️ CHANGE the root password on a real device — and the kvmd admin/admin login
  # (managed via kvmd-htpasswd; seeded in modules/kvmd.nix). They are TWO separate
  # accounts, per the PiKVM handbook.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault true;
    settings.PermitRootLogin = lib.mkDefault "yes";
  };

  # Stock PiKVM's OS account is root/root. Set as the INITIAL password (mutable —
  # `passwd` changes it and the change persists) so a freshly-flashed headless
  # device is reachable the stock way. Harden by overriding this + the SSH
  # settings above.
  users.users.root.initialPassword = lib.mkDefault "root";

  users.users.pikvm = {
    isNormalUser = true;
    description = "PiKVM administrator";
    extraGroups = [ "wheel" ];
    # Optional: pre-seed operator SSH keys for a hardened key-only deployment
    # (pair with services.openssh.settings.PasswordAuthentication = false above).
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
