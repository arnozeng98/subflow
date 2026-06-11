# subflow

subflow turns a VPS already managed by [Tangfffyx/sing-box](https://github.com/Tangfffyx/sing-box)
into a per-user subscription service, fronted by Cloudflare Pages.

Two clearly separated parts:

1. **VPS data API** (`src/subflow`) — a tiny, token-protected service that exposes
   the upstream node data for a single user as raw JSON. It does **no** rendering.
2. **Cloudflare Pages gateway** (`functions/`) — validates the username, fetches
   that raw data, and **generates the complete client configuration** (Clash,
   sing-box, Surge, Quantumult X, Shadowrocket, or a universal URI list) using
   templates and rules pulled from official, continuously-updated sources.

```
client ──> Cloudflare Pages (/<user>?format=…) ──> VPS data API (/internal/raw/<user>)
                  │                                         │
                  │  builds full config from                │  reads upstream
                  │  official rule sources                  ▼
                  ▼                                  /etc/sing-box/config.json
            subscription                            /etc/sing-box-manager/*.json
```

Different usernames yield different nodes and the configuration adapts to the
requesting client automatically.

## Documentation

Full guides live in [docs/](docs/):

- [01 · Architecture](docs/01-architecture.md) — how the pieces fit and data flows.
- [02 · VPS deployment](docs/02-vps-deployment.md) — install the data API.
- [03 · Cloudflare deployment](docs/03-cloudflare-deployment.md) — deploy the gateway.
- [04 · Secrets & configuration](docs/04-secrets-and-config.md) — every variable and secret.
- [05 · Templates & rules](docs/05-templates-and-rules.md) — official sources, caching, overrides.
- [06 · Usage](docs/06-usage.md) — subscription links and client import.

## Quick start

```bash
# 1) On the VPS (already running Tangfffyx/sing-box):
wget -O subflow-install.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/deploy/vps/install.sh && bash subflow-install.sh
# The installer is interactive: it prompts for every setting (public IP, token,
# paths, WS domains). Skipped items can be changed later from the menu.
# Afterwards, run `sf` anytime to open the management menu.

# 2) On Cloudflare: create a Pages project from this repo and set the secrets
#    VPS_API_BASE_URL and VPS_API_BEARER_TOKEN (see docs/03 and docs/04).
```

## Repository layout

- [functions/[user].js](functions/[user].js) — Pages entry point (orchestration only).
- [functions/_lib/](functions/_lib) — gateway modules: config, protocol detection,
  link builders, format negotiation, and the per-platform config generators under
  [functions/_lib/templates/](functions/_lib/templates).
- [src/subflow/](src/subflow) — VPS data API (pure data, no rendering).
- [deploy/vps/](deploy/vps) — interactive installer, `sf` management menu
  ([menu.sh](deploy/vps/menu.sh)), shared library ([lib.sh](deploy/vps/lib.sh)),
  uninstaller, and env example.
- [deploy/cloudflare/](deploy/cloudflare) — local dev vars example.
- [docs/](docs) — deployment and configuration guides.
- [scripts/smoke-test.mjs](scripts/smoke-test.mjs) — local generator smoke test (requires Node 18+).

## Design notes

- **No hard-coded config.** Every operator value is an environment variable; the
  gateway reads them in one place ([functions/_lib/config.js](functions/_lib/config.js))
  and the VPS in [src/subflow/config.py](src/subflow/config.py).
- **Always-latest rules.** Generated configs reference official rule sources
  (Loyalsoldier, SagerNet, blackmatrix7) via the client's native rule-provider /
  rule_set / RULE-SET mechanisms, so rules update without re-hosting.
- **Tenant isolation.** The VPS only ever returns the requesting user's own
  credentials, never other users' secrets.
