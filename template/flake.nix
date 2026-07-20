{
  description = "My PiKVM, built on pikvm-nixos";

  inputs = {
    pikvm-nixos.url = "github:dvaerum/pikvm-nixos";
    # Reuse pikvm-nixos's pinned nixpkgs so everything stays consistent.
    nixpkgs.follows = "pikvm-nixos/nixpkgs";
  };

  outputs =
    { self, pikvm-nixos, nixpkgs }:
    {
      nixosConfigurations.mykvm = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          # The whole PiKVM appliance: universal multi-board image, services,
          # auto-detected platform, package overlay, sensible defaults.
          pikvm-nixos.nixosModules.appliance

          (
            { ... }:
            {
              networking.hostName = "mykvm";

              # Your login key(s) for SSH.
              users.users.pikvm.openssh.authorizedKeys.keys = [
                # "ssh-ed25519 AAAA... you@host"
              ];

              # Have devices self-update from YOUR repo instead of upstream
              # (point this at wherever you host this flake).
              # services.pikvm.autoUpgrade.flake = "github:you/your-pikvm#mykvm";

              # Example kvmd tweak (declarative override):
              # services.pikvm.kvmd.settings = { kvmd.streamer.desired_fps.default = 30; };

              # Pin a specific platform instead of auto-detect, if you like:
              # services.pikvm.kvmd.platform = "v2-hdmi-rpi4";
            }
          )
        ];
      };
    };
}
