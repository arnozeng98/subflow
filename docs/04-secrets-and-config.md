# 04 · Secrets & configuration

Every operator-tunable value is an environment variable. Nothing business-specific
is hard-coded. This page lists them all and how to set the sensitive ones.

## Cloudflare Pages (gateway)

Read in one place: [functions/_lib/config.js](../functions/_lib/config.js).
Non-sensitive defaults live in [wrangler.toml](../wrangler.toml).

| Variable | Required | Type | Default | Purpose |
| --- | --- | --- | --- | --- |
| `VPS_API_BASE_URL` | Yes | **Secret** | — | Base URL of the VPS data API. |
| `VPS_API_BEARER_TOKEN` | Yes | **Secret** | — | Must equal the VPS `SUBFLOW_API_TOKEN`. |
| `VPS_RAW_PATH_TEMPLATE` | No | Var | `/internal/raw/{user}` | Raw endpoint path template. |
| `REQUEST_TIMEOUT_MS` | No | Var | `8000` | Upstream fetch timeout. |
| `TEMPLATE_CACHE_TTL_SECONDS` | No | Var | `21600` | Cache-API TTL for fetched templates. |
| `RESPONSE_CACHE_CONTROL` | No | Var | derived from TTL | Subscription `Cache-Control`. |
| `SUBFLOW_PROFILE_NAME` | No | Var | `Subflow` | Profile name embedded in configs. |
| `SUBFLOW_DEFAULT_FORMAT` | No | Var | `universal` | Format when UA is unknown. |
| `SUBFLOW_CLASH_TEMPLATE_URL` | No | Var | — | Optional Clash base-template override. |
| `SUBFLOW_SINGBOX_TEMPLATE_URL` | No | Var | — | Optional sing-box base-template override. |
| `SUBFLOW_SURGE_TEMPLATE_URL` | No | Var | — | Optional Surge base-template override. |
| `SUBFLOW_QUANTUMULTX_TEMPLATE_URL` | No | Var | — | Optional QX base-template override. |
| `SUBFLOW_SHADOWROCKET_TEMPLATE_URL` | No | Var | — | Optional Shadowrocket base-template override. |
| `SUBFLOW_CLASH_RULES_BASE` | No | Var | Loyalsoldier release | Clash rule-provider base. |
| `SUBFLOW_SINGBOX_GEOSITE_BASE` | No | Var | SagerNet sing-geosite | sing-box geosite rule-set base. |
| `SUBFLOW_SINGBOX_GEOIP_BASE` | No | Var | SagerNet sing-geoip | sing-box geoip rule-set base. |
| `SUBFLOW_BLACKMATRIX7_BASE` | No | Var | blackmatrix7 master | Surge/QX RULE-SET base. |

Template for local dev: [deploy/cloudflare/.dev.vars.example](../deploy/cloudflare/.dev.vars.example).

### Setting Cloudflare secrets

**Dashboard:** project → *Settings* → *Environment variables* → add variable →
toggle *Encrypt* to make it a Secret. Add `VPS_API_BASE_URL` and
`VPS_API_BEARER_TOKEN` as secrets.

**CLI:**

```bash
wrangler pages secret put VPS_API_BASE_URL
wrangler pages secret put VPS_API_BEARER_TOKEN
```

> Do **not** put secrets in `wrangler.toml` or `.dev.vars` committed to Git.
> `.dev.vars` is for local development only and should be git-ignored.

## VPS data API

Read in [src/subflow/config.py](../src/subflow/config.py). Written to
`/etc/subflow/subflow.env` (mode `600`) by the installer. Template:
[deploy/vps/subflow.env.example](../deploy/vps/subflow.env.example).

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `SUBFLOW_API_TOKEN` | Yes | generated | **Secret** Bearer token; must match Cloudflare. |
| `SUBFLOW_PUBLIC_IP` | Yes | — | Public IP/host used as every node's server. |
| `SUBFLOW_LISTEN_HOST` | No | `127.0.0.1` | Bind address. |
| `SUBFLOW_LISTEN_PORT` | No | `28080` | Bind port. |
| `SUBFLOW_CONFIG_PATH` | No | `/etc/sing-box/config.json` | Upstream config. |
| `SUBFLOW_USER_DB_PATH` | No | `/etc/sing-box-manager/user-manager.json` | Upstream users. |
| `SUBFLOW_META_PATH` | No | `/etc/sing-box-manager/meta.json` | Reality metadata. |
| `SUBFLOW_WS_DOMAIN` | No | — | VLESS-WS host override. |
| `SUBFLOW_VMESS_WS_DOMAIN` | No | — | VMess-WS host override. |
| `SUBFLOW_INCLUDE_DISABLED_USERS` | No | `false` | Serve disabled users too. |

### Protecting the VPS env file

```bash
chmod 600 /etc/subflow/subflow.env      # the installer already does this
```

The token is the only credential guarding the data API. Treat it like a password
and rotate it (update both the VPS env and the Cloudflare secret) if exposed.

## The token must match

`SUBFLOW_API_TOKEN` (VPS) and `VPS_API_BEARER_TOKEN` (Cloudflare) are the same
secret on both ends. If they diverge, the gateway gets `403` from the VPS and
returns `502` to clients.
