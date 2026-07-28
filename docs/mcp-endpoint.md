# The `/mcp` endpoint — give an AI agent hands on your PiKVM

pikvm-nixos can expose the [PiKVM MCP server](https://github.com/dvaerum/pikvm_mcp_server)
on the PiKVM's own HTTPS port, so an AI agent can drive the keyboard, mouse and
screen over the [Model Context Protocol](https://modelcontextprotocol.io):

```
https://<your-pikvm>/mcp
```

It is **on by default** — the appliance ships as a faithful PiKVM *plus* this MCP
endpoint. The same nginx front-door that serves the PiKVM web dashboard on 443
also reverse-proxies the MCP server, and the agent authenticates with the **same
login as the PiKVM web UI** (unified auth) — the stock **admin/admin** by default.

> ⚠️ **First boot — change the defaults, like stock PiKVM.** Out of the box the
> OS login is `root`/`root` (SSH) and the web/API/`/mcp` login is `admin`/`admin`
> (two separate accounts, per the PiKVM handbook). Until you change them, anyone
> who can reach the box can drive the KVM **and** the AI agent. Change them:
> `passwd` (root) and `kvmd-htpasswd set admin` (web/API/MCP). Harden further:
> point `services.pikvm-mcp.passwordFile` at a sops/agenix secret, disable `/mcp`
> (`services.pikvm-mcp.enable = false`), disable the web front-door
> (`services.pikvm.web.enable = false`), or switch SSH to keys-only.

## Configure / override it

It's on by default via `pikvm-nixos.nixosModules.appliance`. To change the
defaults (or harden), set the options on your host, e.g.:

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
  services.pikvm.web.enable = true;
}
```

That's the whole appliance side. `security = "kvmd"` means the agent logs in
with a real PiKVM username/password; `services.pikvm.web` gives the MCP
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

To serve your **own** certificate (so verification works normally), point the
proxy at your cert and key:

```nix
services.pikvm.web.tls = {
  certificate    = "/etc/ssl/pikvm/fullchain.pem";           # public — a plain path is fine
  certificateKey = config.sops.secrets."pikvm/tls-key".path; # a RUNTIME secret path
};
```

Both mirror nginx's own `sslCertificate` / `sslCertificateKey`, and pikvm-nixos
passes them to nginx **verbatim** — the private key is never read into or copied
through the Nix store. When both are set nginx uses them; otherwise it self-signs.

### The private key must be a runtime secret path

`certificateKey` must be a **string path that exists at runtime** — the file a
secret manager decrypts on the box — not a Nix path literal:

- ✅ `config.sops.secrets."pikvm/tls-key".path` → `"/run/secrets/pikvm/tls-key"`
- ✅ `config.age.secrets."pikvm-tls-key".path` → `"/run/agenix/pikvm-tls-key"`
- ✅ any `"/var/lib/…"` / `"/run/…"` string you provision yourself
- ❌ `./tls-key.pem` (a Nix path literal) — this **copies the key into the
  world-readable `/nix/store`**. Never do this for a private key.

nginx runs as the `nginx` user, so the key must be **readable by `nginx`**, and
the front-door must not start before the secret is materialized. Both secret
managers below decrypt during system **activation**, before any service starts,
so nginx is already ordered after them — no extra wiring needed. (If you run
sops-nix in its systemd mode instead, add `systemd.services.nginx.after` on the
`sops-install-secrets` unit.)

#### sops-nix

```nix
sops.secrets."pikvm/tls-key" = {
  sopsFile = ./secrets/pikvm.yaml;
  owner = "nginx";      # nginx must read it
  mode  = "0400";
};

services.pikvm.web.tls = {
  certificate    = "/etc/ssl/pikvm/fullchain.pem";
  certificateKey = config.sops.secrets."pikvm/tls-key".path;
};
```

#### agenix

```nix
age.secrets."pikvm-tls-key" = {
  file  = ./secrets/pikvm-tls-key.age;
  owner = "nginx";      # nginx must read it
  mode  = "0400";
};

services.pikvm.web.tls = {
  certificate    = "/etc/ssl/pikvm/fullchain.pem";
  certificateKey = config.age.secrets."pikvm-tls-key".path;
};
```

> The same runtime-secret rule applies to every key the appliance takes —
> `services.pikvm-mcp.passwordFile`, `services.pikvm.hidRecovery.endpoint.tokenFile`,
> etc. Point them at sops/agenix secret paths, never inline strings in the store.

> ACME / Let's Encrypt is not wired up (a LAN appliance usually has no public
> domain), but it's a natural future option if your PiKVM is reachable at a
> real hostname.

## Notes

- The endpoint is path-routed on the **same 443 vhost** as kvmd's API, so it
  coexists with the (future) PiKVM web UI — no extra port.
- `services.pikvm-mcp` can also run standalone against a **remote** PiKVM
  (point `host` at it); the `services.pikvm.web` front-door is only for the local case.
