# The universal PiKVM image — board facts only (Phase 3 architecture split).
#
# ONE flashable SD image that boots on any supported Raspberry Pi and detects
# its hardware at runtime. This is possible because the generic aarch64
# sd-image already ships every board's device tree and boots through the
# Raspberry Pi firmware, which reads config.txt and applies the right overlays
# for whichever board it lands on. We replace that config.txt with a PiKVM one
# (conditional per-board filters); the capture/HID profile itself is picked at
# boot by services.pikvm.kvmd.platform = "auto" (set in
# profiles/appliance-stack.nix, not here — see that file's header for why).
#
# ⚠️ The boot/device-tree/kernel layer is the part that most needs validation
# on real hardware; the software stack and image assembly are validated by
# eval + CI image builds.
{
  modulesPath,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    # Multi-board base: all Pi DTBs + RPi firmware + u-boot. NOT the
    # board-specific nixos-hardware module, which would pin us to one Pi.
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  # Capture-bridge + gadget-networking kernel modules (dwc2/libcomposite come
  # from the OTG module).
  boot.kernelModules = [
    "tc358743"
    "nbd"
  ];

  sdImage.compressImage = true;

  # Replace the stock config.txt with a PiKVM multi-board one. Overlays before
  # the first filter apply to every board; per-board sections tune CMA/gpu_mem
  # and the TC358743 CSI wiring. dwc2 peripheral mode (for USB HID/MSD
  # emulation) is forced on all boards, overriding the base image's CM4
  # otg_mode=host.
  sdImage.populateFirmwareCommands =
    let
      configTxt = pkgs.writeText "config.txt" ''
        kernel=u-boot.bin
        arm_64bit=1
        enable_uart=1
        avoid_warnings=1

        # --- PiKVM, all boards ---
        # Emulate USB keyboard/mouse/mass-storage to the target machine.
        dtoverlay=dwc2,dr_mode=peripheral
        dtoverlay=disable-bt
        hdmi_force_hotplug=1

        [pi3]
        core_freq=250

        [pi4]
        enable_gic=1
        armstub=armstub8-gic.bin
        disable_overscan=1
        arm_boost=1
        dtoverlay=cma,cma-128
        gpu_mem=128
        dtoverlay=tc358743

        [cm4]
        enable_gic=1
        armstub=armstub8-gic.bin
        dtoverlay=cma,cma-128
        gpu_mem=128
        dtoverlay=tc358743
        dtoverlay=tc358743-audio
        dtparam=i2c_arm=on

        [pi02]
        dtoverlay=cma,cma-96
        gpu_mem=96
        dtoverlay=tc358743,i2c_pins_28_29=1

        [all]
      '';
    in
    lib.mkForce ''
      (cd ${pkgs.raspberrypifw}/share/raspberrypi/boot && cp bootcode.bin fixup*.dat start*.elf $NIX_BUILD_TOP/firmware/)
      cp ${pkgs.ubootRaspberryPiAarch64}/u-boot.bin firmware/u-boot.bin
      cp ${configTxt} firmware/config.txt

      # Board device trees (Pi 2/3, Zero 2 W, CM3/4, Pi 4/400, CM4s).
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-2-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-3-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-3-b-plus.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-cm3.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-zero-2.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-zero-2-w.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-4-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-400.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-cm4.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-cm4s.dtb firmware/

      # Pi 4 needs the GIC-enabled armstub.
      cp ${pkgs.raspberrypi-armstubs}/armstub8-gic.bin firmware/armstub8-gic.bin

      # Device-tree overlays (tc358743, dwc2, disable-bt, cma, …).
      mkdir -p firmware/overlays
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/*.dtbo firmware/overlays/
    '';
}
