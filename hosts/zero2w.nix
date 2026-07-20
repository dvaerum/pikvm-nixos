# Raspberry Pi Zero 2 W — the bonus target, on the RPi vendor kernel.
#
# Same PiKVM stack as the Pi 4, on the Zero 2 W's (bcm2710) vendor kernel. The
# TC358743 sits on alternate I2C pins here (i2c_pins_28_29), and less GPU
# memory is reserved to fit the 512 MB board. Install with:
#
#   nix run .#install-sd -- --board zero2w /dev/diskX
{
  lib,
  nixos-raspberrypi,
  disko,
  ...
}:
{
  imports = [
    nixos-raspberrypi.nixosModules.raspberry-pi-02.base
    disko.nixosModules.disko
    ./disko.nix
    ./configtxt-pikvm.nix
  ];

  networking.hostName = "pikvm";

  # Board-specific capture config: TC358743 on the Zero's alternate I2C pins.
  hardware.raspberry-pi.config.all = {
    options.gpu_mem = {
      enable = true;
      value = 96;
    };
    dt-overlays.tc358743 = {
      enable = true;
      params.i2c_pins_28_29 = {
        enable = true;
        value = true;
      };
    };
  };

  services.pikvm.autoUpgrade.flake = lib.mkDefault "github:dvaerum/pikvm-nixos#zero2w";

  services.pikvm.kvmd.enable = true;
  services.pikvm.kvmd.platform = "auto";
  services.pikvm.otg.enable = true;
}
