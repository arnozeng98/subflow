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

The installer is **interactive**: it walks you through every setting at install
time with a guided wizard, so there is no need to hand-edit a file afterwards.
For each item you can:

- type a value, or
- press Enter to accept the shown default (and the Bearer token is generated
  automatically), or
- skip optional items — and change them later from the menu (`sf`).

It then:

1. Downloads the repository archive from GitHub if local source is not present.
2. Copies the service into `/opt/subflow` and the menu/CLI into `/opt/subflow/cli`.
3. Writes `/etc/subflow/subflow.env` (mode `600`) from your answers.
4. Installs the `sf` command at `/usr/local/bin/sf`.
5. Creates and starts `subflow.service` (systemd).
6. Prints the Bearer token — **save it**; Cloudflare needs the same value.

The one value you should not skip is `SUBFLOW_PUBLIC_IP` (the public IP/host that
becomes every node's server address). If you do skip it, the wizard warns you and
you can fill it in later via `sf` → 修改配置.

## The `sf` menu

After installation, run:

```bash
sf
```

This opens a friendly management menu (logo, author, and repo at the top) where
you can view status and full details, edit any setting (including ones skipped
at install — saving restarts the service automatically), start/stop/restart,
toggle autostart, tail logs, update to the latest version, or uninstall.

Non-interactive subcommands are also available:

```bash
sf status      # systemd status
sf info        # full config incl. token
sf edit        # edit configuration
sf start|stop|restart
sf logs        # follow logs
sf update      # pull latest and restart
sf uninstall
```

> See [04 · Secrets & configuration](04-secrets-and-config.md) for every variable.

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

Use the menu (`sf` → 服务开关) or the subcommands / systemd directly:

```bash
sf restart                       # via the menu CLI
# or equivalently:
systemctl status subflow.service
journalctl -u subflow.service -f
systemctl restart subflow.service
```

## Uninstall

From the menu: `sf` → 卸载. Or directly:

```bash
sf uninstall
```

This removes subflow (service, files, and the `sf` command). Your upstream
sing-box runtime and user data are left untouched.
