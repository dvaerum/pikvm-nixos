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
    #
    # PINNED to an explicit rev (not a floating branch) so `nix flake update`
    # can't silently move the appliance's agent surface. This rev carries #51's
    # HID-mode derivation (#46): the MCP derives its mode from the appliance's GET
    # /hidmode and is STATELESS about mode. The URL is wired via the module's
    # first-class `services.pikvm-mcp.hidModeUrl` (hidmode-endpoint.nix), and the
    # appliance sets `target = null` in the same block — so no `--target` is passed
    # (URL-only derive). This rev also carries the module fix that makes a stray
    # `hidModeUrl`+`target` both-set an EVAL error (nullOr target + conditional
    # --target + a mutual-exclusion assertion), so the previous crash-loop trap is
    # now caught by the host eval-gate, not just at runtime. Bump deliberately.
    # (a4bb815 = 00cbfc0 + #49: retunes the MCP drift wording to "next-boot
    # pending / will boot into X" — the matched pair to appliance #53, which sources
    # `requested` from the boot-authoritative yaml; a src change so the MCP package
    # moves. Landed AFTER #53 so the wording never gets ahead of the semantics.)
    pikvm-mcp-server = {
      url = "github:dvaerum/pikvm_mcp_server/9fc430c306b0ea236495f5bb903ae552a43af853";
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

      inherit (import ./lib/eval-gate.nix { inherit lib; }) evalDrvPathOf mkEvalGate mustNotEval;
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
        lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
          let
            # Real VM tests: each builds a system and boots it in a VM; a
            # green build == a passing test. Kept as its own binding (not
            # folded straight into the returned attrset) so `ci-vm-gate`
            # below can reference these by name via `vmTests.${n}` — Nix
            # doesn't allow bare hyphenated identifiers as `rec`
            # self-references (`kvmd-services` alone would parse as
            # subtraction), so dynamic `.${n}` lookup on a plain `let`
            # binding is the idiom, not `rec { }`.
            vmTests = {
              kvmd-services = pkgs.testers.runNixOSTest (
                import ./tests/kvmd-services.nix { inherit self pkgs; }
              );
              hidmode = pkgs.testers.runNixOSTest (import ./tests/hidmode.nix { inherit self pkgs; });
              mcp-proxy = pkgs.testers.runNixOSTest (import ./tests/mcp-proxy.nix { inherit self pkgs; });
              hid-recovery = pkgs.testers.runNixOSTest (
                import ./tests/hid-recovery.nix { inherit self pkgs; }
              );
              hid-latch-monitor = pkgs.testers.runNixOSTest (
                import ./tests/hid-latch-monitor.nix { inherit self pkgs; }
              );
              mcp-hid-recovery-env = pkgs.testers.runNixOSTest (
                import ./tests/mcp-hid-recovery-env.nix { inherit self pkgs; }
              );
              # These 5 stay eval-only in CI (not in ci-vm-gate below) — a
              # recorded decision, not an oversight: webterm/http-redirect/
              # hidmode-web are thin composition checks over already-covered
              # modules (nginx/webterm proper get exercised via the gated
              # tests above; these mainly prove the extra wiring doesn't
              # break eval), otg-mode-assembly is exhaustively covered by its
              # own eval-level eval assertions already, and janus is WIP/
              # default-off (no shipped host enables it yet). Promote any of
              # these to ci-vm-gate if it gains a real hardware-confirmed
              # regression history, same bar as the 7 below.
              webterm = pkgs.testers.runNixOSTest (import ./tests/webterm.nix { inherit self pkgs; });
              http-redirect = pkgs.testers.runNixOSTest (
                import ./tests/http-redirect.nix { inherit self pkgs; }
              );
              hidmode-web = pkgs.testers.runNixOSTest (
                import ./tests/hidmode-web.nix { inherit self pkgs; }
              );
              otg-mode-assembly = pkgs.testers.runNixOSTest (
                import ./tests/otg-mode-assembly.nix { inherit self pkgs; }
              );
              janus = pkgs.testers.runNixOSTest (import ./tests/janus.nix { inherit self pkgs; });
              # Real hardware-confirmed regression (it-03400's DeviceAllow/
              # DevicePolicy crash-loop) — belongs in ci-vm-gate, unlike the
              # 5 above.
              local-display = pkgs.testers.runNixOSTest (
                import ./tests/local-display.nix { inherit self pkgs; }
              );
            };

            # The checks CI actually gates merges on (ci.yml's vm-test job —
            # see docs/running-ci-locally.md §2/§4 for the single command
            # this collapses to). Each has a real, hardware-confirmed
            # regression history (see each test file's own header) — that's
            # the bar for inclusion here, not "every VM test we happen to
            # have". Closes docs/decisions/0004-local-display.md's
            # Consequences claim ("gets caught by CI") — true again as of
            # this check's addition, previously aspirational.
            ciVmGateNames = [
              "kvmd-services"
              "mcp-proxy"
              "hid-recovery"
              "mcp-hid-recovery-env"
              "hid-latch-monitor"
              "hidmode"
              "local-display"
            ];
            missingCiVmGateChecks = lib.filter (n: !(builtins.hasAttr n vmTests)) ciVmGateNames;
          in
          vmTests
          // {
            # Guard against a typo'd/renamed/removed vmTests entry silently
            # dropping coverage from ci-vm-gate below instead of failing
            # loudly at eval.
            ci-vm-gate =
              assert lib.assertMsg (missingCiVmGateChecks == [ ]) ''
                checks.ci-vm-gate names checks that don't exist in vmTests:
                ${builtins.toJSON missingCiVmGateChecks} — a rename or removal
                upstream broke this list without updating it.
              '';
              pkgs.linkFarm "pikvm-ci-vm-gate" (
                map (n: {
                  name = n;
                  path = vmTests.${n};
                }) ciVmGateNames
              );

            # Aggregate-composition gate: (1) force EVALUATION of every shipped
            # host's toplevel — the per-module VM tests above import modules in
            # isolation, so they miss cross-module conflicts that only surface in
            # the assembled host (e.g. two endpoints both assigning pikvm-mcp's
            # single-valued serviceConfig.EnvironmentFile, which fails eval on the
            # real appliance while every per-module test stays green). (2) assert
            # the appliance actually LOADS BOTH MCP-facing endpoints' env files —
            # the list-contribute invariant: both concatenate, neither wins (a
            # future "simplify to one scalar" would still eval, so (1) alone can't
            # catch it). Eval-only (drvPath — no VM, no realise, seconds); see
            # lib/eval-gate.nix for the mechanism.
            host-eval =
              let
                hostDrvs = lib.mapAttrsToList (_: sys: evalDrvPathOf sys) self.nixosConfigurations;
                rpi4RuntimePaths = self.nixosConfigurations.rpi4.config.services.pikvm.runtimePaths;
                applianceMcpEnv =
                  self.nixosConfigurations.rpi4.config.systemd.services.pikvm-mcp.serviceConfig.EnvironmentFile or [ ];
                bothMcpEnvLoaded =
                  builtins.elem rpi4RuntimePaths.hidRecoveryMcpEnv.path applianceMcpEnv
                  && builtins.elem rpi4RuntimePaths.hidmodeMcpEnv.path applianceMcpEnv;
              in
              assert lib.assertMsg bothMcpEnvLoaded
                "appliance pikvm-mcp must load BOTH endpoints' env files (hid-recovery + hidmode); got ${builtins.toJSON applianceMcpEnv}";
              mkEvalGate {
                inherit pkgs;
                name = "pikvm-host-eval";
                drvPaths = hostDrvs;
              };

            # Standalone-consumption gate for the public `nixosModules.appliance`
            # output, mirroring exactly how template/flake.nix consumes it (bare
            # `nixpkgs.lib.nixosSystem` + a hostName override, no repo-internal
            # wiring). hosts/default.nix's `universal` nixosConfiguration happens
            # to compose identically today, so host-eval above already exercises
            # this content — but that's incidental, not guaranteed: if `universal`
            # ever stops being "exactly nixosModules.appliance", this check still
            # catches a break in the actual downstream entry point. Eval-only; see
            # lib/eval-gate.nix for the mechanism (this check's own past bug: it
            # used to return the derivation itself, not even `.drvPath` — `nix
            # build` on it WAS the full appliance build, kernel included).
            appliance-standalone =
              let
                sys = nixpkgs.lib.nixosSystem {
                  # Fixed aarch64-linux, matching hosts/default.nix's `universal`
                  # (and every real PiKVM target) regardless of the evaluating
                  # host's own architecture — eval-only, so no cross-build needed.
                  system = "aarch64-linux";
                  modules = [
                    self.nixosModules.appliance
                    { networking.hostName = "mykvm"; }
                  ];
                };
              in
              mkEvalGate {
                inherit pkgs;
                name = "pikvm-appliance-standalone";
                drvPaths = [ (evalDrvPathOf sys) ];
              };

            # Standalone-composability gate: nixosModules.pikvm is documented
            # (below, this file) as importable WITHOUT nixosModules.mcp-server —
            # this check PROVES that, rather than leaving it an assertion nobody
            # verifies. This is the exact composition that broke once already:
            # every module referencing services.pikvm-mcp.* threw "The option
            # `services.pikvm-mcp' does not exist" at eval, invisible to every
            # OTHER check here because they all go through nixosConfigurations
            # (hosts/), which always bundles mcp-server. Eval-only; see
            # lib/eval-gate.nix for the mechanism.
            module-standalone =
              let
                # Minimal fs/boot stub — just enough for a bare nixosSystem's
                # toplevel to evaluate without a real board's hardware config.
                stub = {
                  fileSystems."/" = {
                    device = "/dev/disk/by-label/NIXOS_SD";
                    fsType = "ext4";
                  };
                  boot.loader.grub.enable = false;
                  services.pikvm.otg.enable = true;
                  services.pikvm.web.enable = true;
                  # hidLatchMonitor's real default package comes from the (here,
                  # absent) MCP module — give it something so ENABLING it
                  # (otg.enable=true defaults it on) doesn't itself fail on the
                  # null-package assertion this same Phase 1 fix added.
                  services.pikvm.hidLatchMonitor.package = pkgs.hello;
                };
                mkSys =
                  extraModules:
                  lib.nixosSystem {
                    inherit system;
                    modules = [ self.nixosModules.pikvm ] ++ extraModules;
                  };
              in
              # NEGATIVE CONTROL, checked first: the same composition WITHOUT the
              # stub must still fail (no fileSystems/boot config — an ordinary,
              # expected NixOS requirement, unrelated to the MCP-optionality bug
              # this Phase 1 fixes). This is the check whose absence let the bug
              # ship: without proof the mechanism can detect A failure, a
              # positive-only check risks silently passing for the wrong reason
              # (e.g. `.drvPath` not forced deeply enough to surface an error).
              assert lib.assertMsg (mustNotEval (evalDrvPathOf (mkSys [ ]))) ''
                checks.module-standalone's negative control failed: nixosModules.pikvm
                ALONE (no fs/boot stub) evaluated successfully. Either something now
                provides fileSystems/boot config by default (update this check's stub
                accordingly) or this check's own failure-detection is broken — in
                either case this check can no longer prove the positive case below
                means what it claims to.
              '';
              mkEvalGate {
                inherit pkgs;
                name = "pikvm-module-standalone";
                drvPaths = [ (evalDrvPathOf (mkSys [ stub ])) ];
              };
          }
        )
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
        mcp-server =
          { lib, pkgs, ... }:
          {
            imports = [ pikvm-mcp-server.nixosModules.default ];
            # DEFAULT-ON with the stock admin/admin creds, like the rest of PiKVM
            # — the /mcp endpoint is built in out of the box (the project goal:
            # "the SAME as PiKVM, just with pikvm_mcp_server") with NO mandatory
            # secret. security="kvmd" unifies client auth with the kvmd htpasswd
            # (admin/admin). HARDEN by pointing passwordFile at a sops/agenix
            # runtime secret + changing the htpasswd, or disable via
            # services.pikvm-mcp.enable = false.
            config.services.pikvm-mcp = {
              enable = lib.mkDefault true;
              security = lib.mkDefault "kvmd";
              host = lib.mkDefault "https://localhost";
              verifySsl = lib.mkDefault false;
              # The general faithful default is a desktop KVM (absolute mouse).
              # A device with relative-only HID (e.g. an iPad target) overrides
              # this per-host — see hosts/rpi4.nix.
              target = lib.mkDefault "desktop";
              # username already defaults to "admin"; the MCP's own kvmd password
              # defaults to the stock "admin" — a well-known default, not a
              # secret, so a world-readable store file is acceptable. Override
              # with a runtime secret path (sops/agenix) to harden.
              passwordFile = lib.mkDefault (pkgs.writeText "pikvm-mcp-default-password" "admin");
            };
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
      # pinned disko PR #1190 + host binfmt for aarch64). (also
      # --board pikvm01 for the iPad-default kiosk, or zero2w)
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
                    echo "usage: nix run .#install-sd -- [--board rpi4|pikvm01|zero2w] /dev/DISK"; exit 0 ;;
                  *) device="$1"; shift ;;
                esac
              done
              if [ -z "$device" ]; then
                echo "error: no target disk given" >&2
                echo "usage: nix run .#install-sd -- [--board rpi4|pikvm01|zero2w] /dev/DISK" >&2
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
