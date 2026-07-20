# PiKVM config.txt overlays, expressed through nixos-raspberrypi's structured
# `hardware.raspberry-pi.config` option (which renders /boot/firmware/config.txt).
#
# The essentials for PiKVM on the vendor kernel:
#   * dwc2 in *peripheral* mode  → emulate USB keyboard/mouse/mass-storage
#   * tc358743                   → HDMI-to-CSI capture bridge
#   * disable-bt + enable_uart   → free the UART, lower power
#   * gpu_mem                    → memory for the video pipeline / HW encoder
#
# ⚠️ CMA sizing and the vc4-kms-v3d interaction are the parts most likely to
# need tuning once tested on a real board.
{ lib, ... }:
{
  hardware.raspberry-pi.config = {
    all = {
      options = {
        enable_uart = {
          enable = true;
          value = true;
        };
        gpu_mem = {
          enable = true;
          value = 128;
        };
        # PiKVM drives the TC358743 explicitly rather than via auto-detect.
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
        # HDMI-over-CSI capture bridge.
        tc358743 = {
          enable = true;
          params = { };
        };
        # Free the PL011 UART and cut idle power.
        disable-bt = {
          enable = true;
          params = { };
        };
      };
    };
  };
}
