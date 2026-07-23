# The `/mcp` endpoint — give an AI agent hands on your PiKVM

pikvm-nixos can expose the [PiKVM MCP server](https://github.com/dvaerum/pikvm_mcp_server)
on the PiKVM's own HTTPS port, so an AI agent can drive the keyboard, mouse and
screen over the [Model Context Protocol](https://modelcontextprotocol.io):

```
https://<your-pikvm>/mcp
```

It is **off by default**. When enabled, the nginx front-door that already
fronts kvmd's API also reverse-proxies the MCP server, and the agent
authenticates with the **same login as the PiKVM web UI** (unified auth).

## Enable it

Add this to your host (e.g. alongside `imports = [ pikvm-nixos.nixosModules.appliance ]`):

```nix
{ config, ... }:
{
  # The MCP server itself.
  services.pikvm-mcp = {
    enable = true;
    target = "desktop";           # "desktop" (absolute mouse) or "ipad" (relative)
    host = "https://localhost";   # reach kvmd through our own nginx /api front-door
    verifySsl = false;            # the front-door serves a self-signed cert by default

    # UNIFIED AUTH: validate each client's credentials against kvmd — the same
    # /etc/kvmd/htpasswd users as the PiKVM web UI. No separate MCP password.
    security = "kvmd";

    # Opt-in: also allow an agent to authenticate its own session in-band via a
    # `login` tool (instead of an HTTP Basic header). Off by default.
    # allowToolLogin = true;

    # The MCP server's OWN credentials for talking to kvmd (moving the mouse,
    # grabbing the screen). Point at a runtime secret — never inline.
    passwordFile = config.sops.secrets."pikvm/password".path;
    # usernameFile = ...;         # optional; defaults to username = "admin"
  };

  # The 443 front-door: proxies kvmd /api + the MCP /mcp.
  services.pikvm.mcpProxy.enable = true;
}
```

That's the whole appliance side. `security = "kvmd"` means the agent logs in
with a real PiKVM username/password; `services.pikvm.mcpProxy` gives the MCP
server the HTTP route to kvmd it needs to validate them.

## Authenticating (client side)

How an agent presents credentials — the HTTP Basic header, the opt-in in-band
`login` tool, and how to handle the self-signed certificate — is documented
once, canonically, in the MCP server's README:

- **[Authenticating to the `/mcp` endpoint](https://github.com/dvaerum/pikvm_mcp_server/blob/main/README.md#authenticating-to-the-mcp-endpoint)**

In short: under `security = "kvmd"` the credentials **are** the user's PiKVM
login. A present-but-wrong header is rejected (401); with `allowToolLogin`, a
client may instead connect without a header and call the `login` tool to
authenticate its session (only `login` is available until it does).

## TLS

By default the front-door generates a **self-signed** certificate at first boot
(PiKVM is a LAN appliance with no public domain), so clients skip certificate
verification — see the client doc above for how.

To serve your **own** certificate (so verification works normally), set:

```nix
services.pikvm.mcpProxy.tls = {
  certificate = "/etc/ssl/pikvm/fullchain.pem";
  certificateKey = config.sops.secrets."pikvm/tls-key".path;  # a runtime secret
};
```

Both mirror nginx's own `sslCertificate`/`sslCertificateKey`. The key must be a
runtime secret path (sops-nix / agenix) — never an inline string in the Nix
store. If both are set, nginx uses them; otherwise it self-signs.

> ACME / Let's Encrypt is not wired up (a LAN appliance usually has no public
> domain), but it's a natural future option if your PiKVM is reachable at a
> real hostname.

## Notes

- The endpoint is path-routed on the **same 443 vhost** as kvmd's API, so it
  coexists with the (future) PiKVM web UI — no extra port.
- `services.pikvm-mcp` can also run standalone against a **remote** PiKVM
  (point `host` at it); the `mcpProxy` front-door is only for the local case.
