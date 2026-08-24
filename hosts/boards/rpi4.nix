# Raspberry Pi 4 — board facts only (Phase 3 architecture split).
#
# Everything here is a HARDWARE fact of the Pi 4 board itself: which vendor
# base module it needs, its disk layout, its config.txt tuning, and how it
# boots. Stack-enablement (hostName/kvmd.enable/otg.enable/self-update ref)
# lives in profiles/appliance-stack.nix + the per-deployment host file
# instead — this file is imported by both hosts/rpi4.nix and
# hosts/it-03400.nix, and must stay silent about anything deployment-specific
# so it means the same thing wherever it's imported.
{
  nixos-raspberrypi,
  disko,
  ...
}:
{
  imports = [
    nixos-raspberrypi.nixosModules.raspberry-pi-4.base
    disko.nixosModules.disko
    ../disko.nix
    ../configtxt-pikvm.nix
  ];

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
}
