{
  description = "PiKVM on NixOS — a declarative, flake-based port of the PiKVM IP-KVM stack";

  inputs = {
    # Stable NixOS 26.05 — the long-term base for the appliance. It already
    # carries Python 3.14 (which kvmd requires) and every kvmd dependency.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Raspberry Pi vendor kernel + firmware + config.txt/overlay support —
    # what PiKVM's TC358743 CSI capture and hardware H.264 actually need.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi";

    # Declarative partitioning + direct-to-SD install. Pinned to PR #1190
    # (cross-compiled disk formatting) so the aarch64 image can be built and
    # written from an x86_64 host.
    disko = {
      url = "github:nix-community/disko?ref=pull/1190/merge";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-raspberrypi,
      disko,
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
      # `pikvm`    — just the services.pikvm.* options + package overlay, to
      #              compose into your own system.
      # `appliance`— the whole opinionated PiKVM system (universal image,
      #              services, defaults) to import and override. Best default
      #              for downstream users who want to build on this.
      nixosModules = rec {
        pikvm = import ./modules;
        appliance = import ./hosts/appliance.nix;
        default = pikvm;
      };

      # ---- NixOS configurations (buildable Pi images) ---------------------
      # Populated in ./hosts; kept lazy so evaluation doesn't require the
      # target system to be available on the evaluating host.
      nixosConfigurations = import ./hosts {
        inherit nixpkgs self;
      };

      # ---- Template ------------------------------------------------------
      # `nix flake init -t github:dvaerum/pikvm-nixos` scaffolds a downstream
      # flake that builds its own PiKVM image on top of this one.
      templates.default = {
        path = ./template;
        description = "A PiKVM system built on pikvm-nixos";
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
