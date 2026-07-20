# Buildable device configurations.
#
#   nix build .#nixosConfigurations.pi4.config.system.build.sdImage
#
# produces a flashable SD-card image; the very same configuration is what the
# device rebuilds itself into on its weekly auto-upgrade.
{
  nixpkgs,
  nixos-hardware,
  self,
}:
let
  mkHost =
    {
      system ? "aarch64-linux",
      modules,
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit nixos-hardware self; };
      modules = [
        self.nixosModules.pikvm
        ./common.nix
      ]
      ++ modules;
    };
in
{
  # Raspberry Pi 4 / CM4 (aarch64).
  pi4 = mkHost { modules = [ ./pi4.nix ]; };
}
