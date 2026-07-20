# Declarative SD/USB disk layout for disko.
#
# Two partitions: a FAT firmware/boot partition the Raspberry Pi firmware reads
# (kernel, config.txt, overlays) and an ext4 root. `disko-install` (see the
# flake's `install-sd` app) formats and installs straight onto the target.
# The device below is a placeholder — the installer overrides it with
# `--disk main /dev/…`, so you never rely on this value being correct.
{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/mmcblk0";
    content = {
      type = "gpt";
      partitions = {
        FIRMWARE = {
          priority = 1;
          type = "0700"; # Microsoft basic data (RPi firmware partition)
          attributes = [ 0 ]; # required partition
          size = "1024M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot/firmware";
            mountOptions = [
              "noatime"
              "noauto"
              "x-systemd.automount"
              "x-systemd.idle-timeout=1min"
            ];
          };
        };
        root = {
          size = "100%";
          type = "8305"; # Linux ARM64 root
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
