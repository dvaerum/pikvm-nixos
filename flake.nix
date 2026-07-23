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
    # AUTO-BUMPED weekly (.github/workflows/update.yml, bare `nix flake update`):
    # `pull/1190/merge` is GitHub's FLOATING auto-merge ref, so each relock
    # re-merges PR #1190 against the latest upstream disko base — keeping disko
    # current AND re-incorporating this cross-compile disk-format patch every
    # bump, as long as the PR stays open. Note: nothing in the VM/build gate
    # exercises install-sd/disko, so a disko regression surfaces only at
    # SD-flash/image-build time (never on a deployed device's auto-update).
    # WHEN PR #1190 MERGES upstream this merge ref may go stale → switch disko to
    # its normal branch (or a tagged release) then.
    disko = {
      url = "github:nix-community/disko?ref=pull/1190/merge";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # PiKVM MCP server — "give AI agents hands": an MCP endpoint that drives a
    # PiKVM's keyboard/mouse/screen. Consumed as a proper flake (its former
    # `nixitin` input was removed upstream), following our nixpkgs so its
    # package builds against the same base as the rest of the image.
    pikvm-mcp-server = {
      url = "github:dvaerum/pikvm_mcp_server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-raspberrypi,
      disko,
      pikvm-mcp-server,
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
        // {
          pikvm-mcp-server = pikvm-mcp-server.packages.${system}.default;
        }
      );

      # ---- Checks (NixOS VM tests) ----------------------------------------
      # Run NATIVELY per host architecture: an x86_64 host boots an x86_64
      # guest, an aarch64 host an aarch64 guest — no cross-arch emulated VM.
      # Exercises the service/config/detector logic; the Pi vendor-kernel +
      # TC358743 capture path still needs real hardware.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          kvmd-services = pkgs.testers.runNixOSTest (
            import ./tests/kvmd-services.nix { inherit self pkgs; }
          );
          mcp-proxy = pkgs.testers.runNixOSTest (
            import ./tests/mcp-proxy.nix { inherit self pkgs; }
          );
          hid-recovery = pkgs.testers.runNixOSTest (
            import ./tests/hid-recovery.nix { inherit self pkgs; }
          );
        }
      );

      # ---- NixOS modules --------------------------------------------------
      # `pikvm`    — just the services.pikvm.* options + package overlay, to
      #              compose into your own system.
      # `appliance`— the whole opinionated PiKVM system (universal image,
      #              services, defaults) to import and override. Best default
      #              for downstream users who want to build on this.
      nixosModules = rec {
        pikvm = import ./modules;
        # The upstream MCP server's NixOS service (services.pikvm-mcp),
        # re-exposed so devices and downstream users can enable it. Off unless
        # `services.pikvm-mcp.enable = true`. Its nixosModules.default
        # self-provides the package (services.pikvm-mcp.package default), so no
        # global overlay is needed.
        mcp-server = {
          imports = [ pikvm-mcp-server.nixosModules.default ];
        };
        appliance = {
          imports = [
            (import ./hosts/appliance.nix)
            mcp-server
          ];
        };
        default = pikvm;
      };

      # ---- NixOS configurations (buildable Pi images) ---------------------
      # Populated in ./hosts; kept lazy so evaluation doesn't require the
      # target system to be available on the evaluating host.
      nixosConfigurations = import ./hosts {
        inherit nixpkgs nixos-raspberrypi disko self;
      };

      # ---- Apps: direct-to-SD installer ----------------------------------
      # `nix run .#install-sd -- --board rpi4 /dev/diskX` formats and installs
      # onto the card via disko (cross-buildable from x86_64 thanks to the
      # pinned disko PR #1190 + host binfmt for aarch64).
      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          installer = pkgs.writeShellApplication {
            name = "install-sd";
            runtimeInputs = [ disko.packages.${system}.disko-install ];
            text = ''
              set -euo pipefail
              board=rpi4
              device=""
              while [ $# -gt 0 ]; do
                case "$1" in
                  --board) board="''${2:?--board needs a value}"; shift 2 ;;
                  -h|--help)
                    echo "usage: nix run .#install-sd -- [--board rpi4] /dev/DISK"; exit 0 ;;
                  *) device="$1"; shift ;;
                esac
              done
              if [ -z "$device" ]; then
                echo "error: no target disk given" >&2
                echo "usage: nix run .#install-sd -- [--board rpi4] /dev/DISK" >&2
                exit 1
              fi
              echo ">> Installing pikvm-nixos '$board' to $device"
              echo ">> WARNING: this ERASES $device"
              exec disko-install --flake "${self}#$board" --disk main "$device"
            '';
          };
        in
        {
          install-sd = {
            type = "app";
            program = pkgs.lib.getExe installer;
          };
          default = self.apps.${system}.install-sd;
        }
      );

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
