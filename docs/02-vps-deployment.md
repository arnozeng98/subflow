# 02 · VPS deployment

The VPS service is the private data API. Install it on the same machine that runs
Tangfffyx/sing-box.

## Prerequisites

- A VPS already running [Tangfffyx/sing-box](https://github.com/Tangfffyx/sing-box)
  with at least one user configured.
- `python3` (3.9+) available.
- `root` access.
- `curl` or `wget` (the installer uses them to fetch the repo archive).

## Install

```bash
wget -O subflow-install.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/deploy/vps/install.sh
bash subflow-install.sh
```

The installer:

1. Downloads the repository archive from GitHub if local source is not present.
2. Copies the service into `/opt/subflow`.
3. Writes `/etc/subflow/subflow.env` (mode `600`) with a generated Bearer token.
4. Creates and starts `subflow.service` (systemd).
5. Prints the Bearer token — **save it**; Cloudflare needs the same value.

## Required configuration

Edit `/etc/subflow/subflow.env` and set the public address clients connect to:

```ini
SUBFLOW_PUBLIC_IP=203.0.113.10        # REQUIRED: becomes every node's server
SUBFLOW_WS_DOMAIN=ws.example.com      # only if VLESS-WS sits behind a CDN
SUBFLOW_VMESS_WS_DOMAIN=vm.example.com
```

Then restart:

```bash
systemctl restart subflow.service
```

> Without `SUBFLOW_PUBLIC_IP`, generated nodes have no usable server address.
> See [04 · Secrets & configuration](04-secrets-and-config.md) for all variables.

## Verify

The service listens on `127.0.0.1:28080` by default. Test locally on the VPS:

```bash
# Health check (no auth):
curl -s http://127.0.0.1:28080/healthz        # -> ok

# Raw data for a real username (auth required):
TOKEN=$(awk -F= '/^SUBFLOW_API_TOKEN=/{print $2}' /etc/subflow/subflow.env)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:28080/internal/raw/alice | head -c 400
```

A valid user returns JSON containing `inbounds`, `meta`, `public_ip`,
`ws_domains`, and `usage`. An unknown or disabled user returns `404`.

## Exposing the API to Cloudflare

Cloudflare must reach this endpoint. Recommended: put it behind a reverse proxy
(Caddy/Nginx) on a hostname with TLS, restricted to Cloudflare, e.g.
`https://api.example.com` → `127.0.0.1:28080`. Keep the Bearer token secret; it
is the only thing protecting the data API.

## Service management

```bash
systemctl status subflow.service
journalctl -u subflow.service -f
systemctl restart subflow.service
```

## Uninstall

```bash
wget -O subflow-uninstall.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/deploy/vps/uninstall.sh
bash subflow-uninstall.sh
```

This removes only subflow. Your upstream sing-box runtime and user data are left
untouched.
