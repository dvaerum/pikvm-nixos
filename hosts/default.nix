# Buildable device configurations.
#
# Vendor-kernel, per-board targets built with nixos-raspberrypi (Pi 4 is the
# required one; Zero 2 W to follow). Install straight to a card with:
#
#   nix run .#install-sd -- --board rpi4 /dev/diskX      # format + install
#
# The older mainline multi-board `universal` image is kept as the "literally
# one image file" fallback (build its sdImage as before).
{
  nixpkgs,
  nixos-raspberrypi,
  disko,
  self,
}:
{
  # Raspberry Pi 4 — required target, RPi vendor kernel + disko.
  rpi4 = nixos-raspberrypi.lib.nixosSystem {
    specialArgs = { inherit self nixos-raspberrypi disko; };
    modules = [
      self.nixosModules.pikvm
      self.nixosModules.mcp-server
      ./common.nix
      ./rpi4.nix
    ];
  };

  # Raspberry Pi Zero 2 W — bonus target, RPi vendor kernel + disko.
  zero2w = nixos-raspberrypi.lib.nixosSystem {
    specialArgs = { inherit self nixos-raspberrypi disko; };
    modules = [
      self.nixosModules.pikvm
      self.nixosModules.mcp-server
      ./common.nix
      ./zero2w.nix
    ];
  };

  # Mainline, multi-board single image (Pi 4 + Zero 2 W). Fallback / image-file
  # path; weaker CSI capture than the vendor kernel.
  universal = nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    specialArgs = { inherit self; };
    modules = [ self.nixosModules.appliance ];
  };
}
