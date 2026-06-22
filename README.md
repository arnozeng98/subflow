# subflow

subflow turns a VPS into a per-user subscription service, fronted by Cloudflare
Pages. It bundles its own sing-box multi-user manager (vendored under
[vps/singbox](vps/singbox)), so no separate installation is required.

Two clearly separated parts:

1. **VPS data API** (`vps/subflow`) — a tiny, token-protected service that exposes
   one user's sing-box node data as raw JSON. It does **no** rendering.
2. **Cloudflare Pages gateway** (`functions/`) — validates the username, fetches
   that raw data, and **generates the complete client configuration** (Clash,
   sing-box, Surge, Quantumult X, Shadowrocket, or a universal URI list) using
   templates and rules pulled from official, continuously-updated sources.

```
client ──> Cloudflare Pages (/<user>?format=…) ──> VPS data API (/internal/raw/<user>)
                  │                                         │
                  │  builds full config from                │  reads sing-box
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
# 1) On the VPS (installs sing-box + the data API):
wget -O subflow-install.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/vps/deploy/install.sh && bash subflow-install.sh
# The installer is interactive: it prompts for every setting (public IP, token,
# paths, WS domains). Skipped items can be changed later from the menu.
# Choose "VPS API only" or "VPS API + Cloudflare 自动部署" at the start.
# Afterwards, run `sf` anytime to open the management menu.

# 2) Cloudflare gateway — either let the installer do it automatically
#    (one command, Wrangler Direct Upload, no fork / no GitHub token), or later:
sf deploy
#    It also installs cloudflared and creates a Cloudflare Tunnel so the
#    localhost API is reachable without opening any inbound port (the VPS :443
#    used by sing-box stays free). The API token needs 4 permissions:
#    Account → Cloudflare Pages → Edit, Account → Cloudflare Tunnel → Edit,
#    Zone → DNS → Edit, Zone → Zone → Read.
#    Manual dashboard/CLI setup is also documented (see docs/03 and docs/04).
```

## Repository layout

- [cloudflare/functions/[user].js](cloudflare/functions/[user].js) — Pages entry point (orchestration only).
- [cloudflare/functions/_lib/](cloudflare/functions/_lib) — gateway modules: config, protocol detection,
  link builders, format negotiation, and the per-platform config generators under
  [cloudflare/functions/_lib/templates/](cloudflare/functions/_lib/templates).
- [vps/subflow/](vps/subflow) — VPS data API (pure data, no rendering).
- [vps/singbox/](vps/singbox) — bundled sing-box multi-user manager (the `s` command).
- [vps/deploy/](vps/deploy) — interactive installer, `sf` management menu
  ([menu.sh](vps/deploy/menu.sh)), shared library ([lib.sh](vps/deploy/lib.sh)),
  Cloudflare auto-deploy ([cf-deploy.sh](vps/deploy/cf-deploy.sh)),
  uninstaller, and env example.
- [cloudflare/deploy/](cloudflare/deploy) — local dev vars example.
- [configs/](configs) — shared default values (single YAML source).
- [docs/](docs) — deployment and configuration guides.
- [scripts/smoke-test.mjs](scripts/smoke-test.mjs) — local generator smoke test (requires Node 18+).

## Design notes

- **No hard-coded config.** Every operator value is an environment variable; the
  gateway reads them in one place ([cloudflare/functions/_lib/config.js](cloudflare/functions/_lib/config.js))
  and the VPS in [vps/subflow/config.py](vps/subflow/config.py).
- **Always-latest rules.** Generated configs reference official rule sources
  (Loyalsoldier, SagerNet, blackmatrix7) via the client's native rule-provider /
  rule_set / RULE-SET mechanisms, so rules update without re-hosting.
- **Tenant isolation.** The VPS only ever returns the requesting user's own
  credentials, never other users' secrets.
