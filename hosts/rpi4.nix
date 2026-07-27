# Raspberry Pi 4 — the required target, on the Raspberry Pi vendor kernel.
#
# Built with nixos-raspberrypi.lib.nixosSystem (see hosts/default.nix), which
# supplies the vendor kernel/firmware/bootloader that PiKVM's TC358743 capture
# and hardware H.264 need. Disk layout comes from disko so the image can be
# formatted + installed straight to a card via `nix run .#install-sd`.
{
  lib,
  nixos-raspberrypi,
  disko,
  ...
}:
{
  imports = [
    nixos-raspberrypi.nixosModules.raspberry-pi-4.base
    disko.nixosModules.disko
    ./disko.nix
    ./configtxt-pikvm.nix
  ];

  networking.hostName = "pikvm";

  # Board-specific capture config: TC358743 CSI bridge + GPU memory.
  hardware.raspberry-pi.config.all = {
    options.gpu_mem = {
      enable = true;
      value = 128;
    };
    dt-overlays.tc358743 = {
      enable = true;
      params = { };
    };
  };

  # Devices self-update from this configuration (attribute `rpi4`).
  services.pikvm.autoUpgrade.flake = lib.mkDefault "github:dvaerum/pikvm-nixos#rpi4";

  # The PiKVM stack. Board is known here, but the detector still resolves the
  # capture/HID profile (CSI vs USB) at boot.
  services.pikvm.kvmd.enable = true;
  services.pikvm.kvmd.platform = "auto";
  services.pikvm.otg.enable = true;

  # ---- AI-agent /mcp stack (HELD — review-ready, NOT a go-live config) ------
  # Turns the appliance into a network service for the first time beyond SSH:
  # opens HTTPS 443, serves /mcp behind unified PiKVM-login auth, and enables the
  # HID-recovery loop. rpi4-ONLY (the MCP server pulls onnxruntime — too heavy
  # for the Zero 2 W). DO NOT MERGE to the live host until: the faded-cursor
  # click fix + M6/M8 land, the user gives explicit go-live OK, AND the user
  # provisions the passwordFile secret below. Enabling it also makes the rpi4
  # toplevel build the MCP server (onnxruntime, aarch64) — expect a heavier CI
  # build at go-live.
  services.pikvm.mcpProxy.enable = true; # nginx TLS 443 front-door (kvmd /api + /mcp); OPENS firewall 443

  services.pikvm-mcp = {
    enable = true;
    # CONFIRM AT GO-LIVE: "desktop" (absolute mouse) vs "ipad" (relative) — set
    # to what the kiosk actually drives. Defaulting to desktop pending that.
    target = "desktop";
    host = "https://localhost"; # reach kvmd through our own nginx /api front-door
    verifySsl = false; # the front-door serves a self-signed cert by default
    security = "kvmd"; # unified auth: clients log in with their PiKVM web credentials

    # The MCP server's OWN credentials for driving kvmd (mouse/screen). MUST be a
    # RUNTIME secret path that the user provisions at go-live — NEVER a Nix path
    # literal (a literal copies the password into the world-readable /nix/store).
    # sops-nix/agenix is NOT wired into this repo yet; at go-live either add it
    # and point this at config.sops.secrets."pikvm-mcp/password".path, or
    # materialise the file at this path another way. Stub path only — no secret
    # value lives here or in the store.
    passwordFile = "/run/secrets/pikvm-mcp-password";
  };

  # Authenticated loopback HID-recovery endpoint (127.0.0.1:8082 — NO open
  # port). Pulls in the privileged pikvm-hid-recover@ units + polkit, and
  # auto-wires PIKVM_HID_RECOVERY_URL/_TOKEN into the MCP env (M0/M4 loop).
  services.pikvm.hidRecovery.endpoint.enable = true;
}
