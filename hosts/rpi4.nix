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

  # Board-specific capture config: TC358743 CSI bridge + GPU memory.
  hardware.raspberry-pi.config.all = {
    options.gpu_mem = {
      enable = true;
      value = 128;
    };
    dt-overlays.tc358743 = {
      enable = true;
      params = { };
    };
  };

  # Devices self-update from this configuration (attribute `rpi4`).
  services.pikvm.autoUpgrade.flake = lib.mkDefault "github:dvaerum/pikvm-nixos#rpi4";

  # The PiKVM stack. Board is known here, but the detector still resolves the
  # capture/HID profile (CSI vs USB) at boot.
  services.pikvm.kvmd.enable = true;
  services.pikvm.kvmd.platform = "auto";
  services.pikvm.otg.enable = true;

  # DIRECT-KERNEL BOOT — bypass U-Boot. The default (bootloader = "uboot") has
  # the GPU firmware load mainline U-Boot (uboot-rpi_arm64_defconfig-2026.04),
  # which then boots via extlinux. On a real Pi 4 that U-Boot's SD driver fails
  # to (re)initialise the card — "Card did not respond to voltage select! -110"
  # (NOT power: verified 5.1V/3A) — so it can't read extlinux from the ext4
  # root, falls back to its UEFI bootflow (for which our disko layout has no ESP
  # anyway), and fails to boot. The GPU firmware itself reads the SD + config.txt
  # fine (it loaded U-Boot), so boot the vendor kernel DIRECTLY from config.txt
  # (kernel=kernel.img + initramfs, os_prefix generations) and skip U-Boot
  # entirely — killing both the SD-init failure and the missing-ESP path.
  boot.loader.raspberry-pi.bootloader = "kernel";

  # This kiosk's KVM target is an iPad — relative-only HID (absolute mouse is a
  # no-op there). Override the general "desktop" default for the built-in MCP.
  services.pikvm-mcp.target = "ipad";
}
