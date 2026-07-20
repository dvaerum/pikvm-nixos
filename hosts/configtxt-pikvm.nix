# PiKVM config.txt overlays, expressed through nixos-raspberrypi's structured
# `hardware.raspberry-pi.config` option (which renders /boot/firmware/config.txt).
#
# Board-independent essentials for PiKVM on the vendor kernel:
#   * dwc2 in *peripheral* mode  → emulate USB keyboard/mouse/mass-storage
#   * disable-bt + enable_uart   → free the UART, lower power
#   * camera_auto_detect off     → PiKVM drives the TC358743 explicitly
#
# Board-specific pieces (the tc358743 variant, gpu_mem/CMA sizing) live in the
# per-board host files, since e.g. the Zero 2 W needs tc358743 on alternate I2C
# pins.
#
# ⚠️ CMA sizing and the vc4-kms-v3d interaction are the parts most likely to
# need tuning once tested on a real board.
{ ... }:
{
  hardware.raspberry-pi.config.all = {
    options = {
      enable_uart = {
        enable = true;
        value = true;
      };
      camera_auto_detect = {
        enable = true;
        value = false;
      };
    };
    dt-overlays = {
      # USB gadget to the target machine.
      dwc2 = {
        enable = true;
        params.dr_mode = {
          enable = true;
          value = "peripheral";
        };
      };
      # Free the PL011 UART and cut idle power.
      disable-bt = {
        enable = true;
        params = { };
      };
    };
  };
}
