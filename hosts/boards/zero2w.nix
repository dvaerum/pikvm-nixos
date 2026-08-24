# Raspberry Pi Zero 2 W — board facts only (Phase 3 architecture split).
#
# Everything here is a HARDWARE fact of the Zero 2 W board itself. See
# hosts/boards/rpi4.nix's header for why stack-enablement lives elsewhere.
{
  nixos-raspberrypi,
  disko,
  ...
}:
{
  imports = [
    nixos-raspberrypi.nixosModules.raspberry-pi-02.base
    disko.nixosModules.disko
    ../disko.nix
    ../configtxt-pikvm.nix
  ];

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
}
