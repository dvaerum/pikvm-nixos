# Raspberry Pi 4 — the required target, on the Raspberry Pi vendor kernel.
#
# Built with nixos-raspberrypi.lib.nixosSystem (see hosts/default.nix), which
# supplies the vendor kernel/firmware/bootloader that PiKVM's TC358743 capture
# and hardware H.264 need. Disk layout comes from disko so the image can be
# formatted + installed straight to a card via `nix run .#install-sd`.
{
  lib,
  nixos-raspberrypi,
  disko,
  ...
}:
{
  imports = [
    nixos-raspberrypi.nixosModules.raspberry-pi-4.base
    disko.nixosModules.disko
    ./disko.nix
    ./configtxt-pikvm.nix
  ];

  networking.hostName = "pikvm";

  # Devices self-update from this configuration (attribute `rpi4`).
  services.pikvm.autoUpgrade.flake = lib.mkDefault "github:dvaerum/pikvm-nixos#rpi4";

  # The PiKVM stack. Board is known here, but the detector still resolves the
  # capture/HID profile (CSI vs USB) at boot.
  services.pikvm.kvmd.enable = true;
  services.pikvm.kvmd.platform = "auto";
  services.pikvm.otg.enable = true;
}
