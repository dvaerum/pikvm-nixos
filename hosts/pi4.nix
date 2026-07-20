# Raspberry Pi 4 / CM4 target.
#
# Pulls in the board support from nixos-hardware and the aarch64 SD-image
# builder so `config.system.build.sdImage` yields a flashable image. PiKVM
# service/OTG specifics are added by the pikvm modules as they land.
{
  modulesPath,
  nixos-hardware,
  ...
}:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    nixos-hardware.nixosModules.raspberry-pi-4
  ];

  networking.hostName = "pi4";

  # The USB-C port must run as a device (gadget) to emulate keyboard/mouse/MSD
  # to the target machine; the dwc2 OTG stack is configured by the OTG module.

  # Keep the image small enough to flash quickly.
  sdImage.compressImage = true;
}
