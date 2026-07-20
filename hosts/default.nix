# Buildable device configuration.
#
#   nix build .#nixosConfigurations.universal.config.system.build.sdImage
#
# produces the single universal SD-card image: it boots on any supported
# Raspberry Pi (validated priority: Pi 4 and Pi Zero 2 W; also CM4) and
# detects its hardware at runtime. The same configuration is what each device
# rebuilds itself into on its weekly auto-upgrade.
{
  nixpkgs,
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
      specialArgs = { inherit self; };
      modules = [
        self.nixosModules.pikvm
        ./common.nix
      ]
      ++ modules;
    };
in
{
  universal = mkHost { modules = [ ./universal.nix ]; };
}
