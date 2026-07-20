# Buildable device configuration.
#
#   nix build .#nixosConfigurations.universal.config.system.build.sdImage
#
# produces the single universal SD-card image: it boots on any supported
# Raspberry Pi (required: Pi 4; bonus: Pi Zero 2 W; also CM4) and detects its
# hardware at runtime. The same configuration is what each device rebuilds
# itself into on its weekly auto-upgrade.
#
# The system itself is the reusable `appliance` module, so this is a thin
# wrapper — downstream users import that module the same way (see ./template).
{
  nixpkgs,
  self,
}:
{
  universal = nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    specialArgs = { inherit self; };
    modules = [ self.nixosModules.appliance ];
  };
}
