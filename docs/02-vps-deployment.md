# 02 · VPS deployment

For centralized multi-server management, also follow
[agent enrollment](08-central-management.md#join-each-vps).
The private API and Tunnel described here are optional in central mode.

## Requirements

- Linux amd64 or arm64 with systemd.
- Root access for installation and operating-system changes.
- `curl` or `wget`, `tar`, and `sha256sum` for the bootstrap.
- A published `subflow-v*` release, or a locally built application archive.

Python is not required. The private API and manager are native Go commands.
Node.js is only needed if this machine also deploys the Cloudflare gateway.

## Install

```bash
curl -fL https://raw.githubusercontent.com/arnozeng98/subflow/main/deploy/install.sh \
  -o subflow-install.sh
bash subflow-install.sh
```

The bootstrap downloads an application archive and verifies its checksum before
starting the Go installer. It does not implement users, protocols, quotas, or
Cloudflare provisioning in Shell.

It accepts either curl or wget. On Debian, missing bootstrap tools can be
installed through apt after confirmation (or explicit `--yes`). The native
installer separately checks dependencies for the selected operations. Declining
installation, apt failures, failed downloads and checksum mismatches stop the
operation; they are not reported as successful installs.

Keep the generated API token private and configure the same value as
`VPS_API_BEARER_TOKEN` in Cloudflare. Set `SUBFLOW_PUBLIC_IP` before importing
nodes into clients.

For an existing installation, read [Migration](07-migration.md) first. Do not
delete the sing-box data directories or uninstall the running kernel to upgrade
only the subflow application.

## Commands

```bash
subflow help
sf                  # deployment management
s                   # sing-box management
sf status
sf info
sf edit
sf start
sf stop
sf restart
sf logs
sf update
sf deploy
sf uninstall
```

The API runs as `subflow serve`. Existing `SUBFLOW_*` variables are read from
`/etc/subflow/subflow.env`, with process environment variables taking precedence.
Use `subflow --env-file <path> <command>` for an explicit alternate file.
Env files contain literal `KEY=value` assignments, not executable Shell.

## Certificates and accounting-safe lifecycle

Self-signed certificates only bootstrap a new TLS inbound. Before production
use, configure trusted certificates through native sing-box ACME DNS-01:

```bash
subflow protocol acme --tag trojan --domain proxy.example.com \
  --email operator@example.com --token-file /root/cloudflare-dns-token
```

The token file must be protected from other users. Give its Cloudflare token
only the required DNS access to the certificate's zone. The manager stores
imported credentials in protected server state; subscription projections never
include them. ACME requires a kernel built with `with_acme`; the manager chooses
the supported inline/provider configuration, and the kernel handles renewal.
DNS must be controlled by the selected account; issuing a real certificate
still requires a successful ACME challenge.

Alternatively, import an existing trusted certificate and matching key:

```bash
subflow protocol certificate-import --tag trojan \
  --cert-file /secure/fullchain.pem --key-file /secure/private-key.pem \
  --server-name proxy.example.com
```

Use `subflow kernel start|stop|restart|update` rather than restarting sing-box
directly through systemctl. Managed operations collect counters before stopping
the kernel. Updates validate the candidate first, hold traffic during replacement,
and restore eligible users only through the manager's checked startup path.
If accounting or rollback fails, the command fails explicitly; retain the
reported recovery files rather than forcing an unaccounted restart.

For an external, operator-controlled kernel replacement:

```bash
subflow system prepare-restart
# Replace and validate the kernel while the durable hold remains in effect.
subflow system start
```

Do not stop the kernel before `prepare-restart`: doing so loses its in-memory
counters. Direct systemctl operations, crashes and hard power loss cannot provide
the same accounting guarantee.

## Verify the private API

Both health and raw-data requests require the bearer token:

```bash
read -r -s -p "API token: " TOKEN
printf '\n'
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:28080/healthz
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:28080/internal/raw/alice
unset TOKEN
```

Expected responses:

| Condition | Status |
| --- | --- |
| Healthy process and correct token | `200` |
| Valid user with available nodes | `200` |
| Missing/wrong token | `403` |
| Unknown/disabled user or no assigned nodes | `404` |
| Corrupt/unreadable required state | `503`, with diagnostic logging |

Startup rejects an empty API token. This avoids appearing to run successfully
when every authenticated request would be rejected.

## Public access

Keep the API bound to `127.0.0.1`. Use `sf deploy` to provision Cloudflare
Pages and a Tunnel, or follow [manual deployment](03-cloudflare-deployment.md).
The Tunnel connects outbound and does not consume the sing-box listener on
port 443.

## Uninstall and recovery

Application uninstall must retain sing-box configuration, users, metadata and
the separately installed kernel. Kernel uninstall is a separate management
operation. Keep a backup of the application binary, env file, service units and
all data files before migrating a production machine.
