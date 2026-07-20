{
  description = "PiKVM on NixOS — a declarative, flake-based port of the PiKVM IP-KVM stack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Raspberry Pi board support (device trees, firmware, board profiles).
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # Systems on which we expose packages / devShells. The KVM itself is
      # aarch64-linux (Raspberry Pi); x86_64-linux is kept for CI and for
      # building images via cross-compilation / remote builders.
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
    in
    {
      # ---- Packages (PiKVM-specific derivations) --------------------------
      # Consumed as an overlay so they compose cleanly with nixpkgs and with
      # cross-compilation for the Pi.
      overlays.default = import ./overlays;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        (import ./pkgs { inherit pkgs; })
      );

      # ---- NixOS modules --------------------------------------------------
      nixosModules = rec {
        pikvm = import ./modules;
        default = pikvm;
      };

      # ---- NixOS configurations (buildable Pi images) ---------------------
      # Populated in ./hosts; kept lazy so evaluation doesn't require the
      # target system to be available on the evaluating host.
      nixosConfigurations = import ./hosts {
        inherit nixpkgs nixos-hardware self;
      };

      # ---- Dev ergonomics -------------------------------------------------
      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixfmt-rfc-style
              nix-tree
            ];
          };
        }
      );
    };
}
