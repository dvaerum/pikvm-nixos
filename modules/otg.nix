# USB OTG gadget.
#
# PiKVM emulates a keyboard, mouse and mass-storage device to the target
# machine over the Pi's USB-C/OTG port. The gadget is assembled at boot by
# `kvmd-otg` writing to configfs (usb_gadget), which needs the dwc2 UDC driver
# and libcomposite loaded, configfs mounted, and — crucially — the firmware
# must run the port in peripheral mode (`dtoverlay=dwc2,dr_mode=peripheral`),
# which is set per board in the host config.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pikvm.otg;
in
{
  options.services.pikvm.otg = {
    enable = lib.mkEnableOption "the PiKVM USB OTG gadget (emulated HID + MSD)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pikvm.kvmd;
      defaultText = lib.literalExpression "pkgs.pikvm.kvmd";
      description = "The kvmd package providing kvmd-otg.";
    };
  };

  config = lib.mkIf cfg.enable {
    # dwc2 is the Pi UDC driver; libcomposite backs the configfs gadget. The
    # per-function drivers (usb_f_hid, usb_f_mass_storage, …) autoload by
    # modalias when kvmd-otg creates their configfs directories.
    boot.kernelModules = [
      "dwc2"
      "libcomposite"
    ];

    # kvmd-otg writes the gadget under /sys/kernel/config/usb_gadget; systemd
    # mounts configfs there on demand via sys-kernel-config.mount.

    # Oneshot mirroring upstream kvmd-otg.service: build the gadget on start,
    # tear it down on stop, and stay "active" in between so kvmd can depend on
    # it. Must run after the function modules are loaded and before kvmd.
    systemd.services.kvmd-otg = {
      description = "PiKVM OTG gadget";
      after = [ "systemd-modules-load.service" ];
      before = [ "kvmd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/kvmd-otg start";
        ExecStop = "${cfg.package}/bin/kvmd-otg stop";
      };
    };
  };
}
