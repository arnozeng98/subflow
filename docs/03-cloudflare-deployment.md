# 03 · Cloudflare deployment

The Cloudflare Pages project is the public gateway and the place where all client
configurations are generated.

## Prerequisites

- A Cloudflare account.
- This repository pushed to GitHub (or connected directly).
- The VPS data API reachable over HTTPS (see [02 · VPS deployment](02-vps-deployment.md)).
- The Bearer token printed by the VPS installer.

## Option A — Dashboard (recommended)

1. **Create the project.** Cloudflare Dashboard → *Workers & Pages* → *Create* →
   *Pages* → *Connect to Git* → select this repository.
2. **Build settings.** There is no build step. Leave *Framework preset* as
   *None*, *Build command* empty, and *Build output directory* as `/` (the
   `functions/` directory is detected automatically).
3. **Set variables and secrets** (see [04 · Secrets & configuration](04-secrets-and-config.md)):
   - Secret: `VPS_API_BASE_URL`
   - Secret: `VPS_API_BEARER_TOKEN`
   - (Optional vars come from [wrangler.toml](../wrangler.toml) defaults; override
     in the dashboard if needed.)
4. **Deploy.** Trigger the first deployment.
5. **Custom domain.** *Custom domains* → add e.g. `sub.example.com`.

## Option B — Wrangler CLI

```bash
npm install -g wrangler
wrangler login

# Set secrets (prompted, not echoed):
wrangler pages secret put VPS_API_BASE_URL
wrangler pages secret put VPS_API_BEARER_TOKEN

# Deploy:
wrangler pages deploy
```

## Local development

```bash
cp deploy/cloudflare/.dev.vars.example .dev.vars
# edit .dev.vars with a reachable VPS base URL + token
wrangler pages dev
```

Then exercise the gateway:

```bash
curl -s "http://localhost:8788/alice?format=clash" | head -c 400
curl -s "http://localhost:8788/alice?format=singbox" | head -c 400
curl -s "http://localhost:8788/doesnotexist" -o /dev/null -w "%{http_code}\n"  # 404
```

## Verify production

After deploying with a custom domain:

```bash
curl -s "https://sub.example.com/alice?format=clash" | head
curl -s "https://sub.example.com/alice?format=singbox" | python3 -m json.tool >/dev/null && echo "valid JSON"
```

- A valid user returns a complete configuration for the requested format.
- An unknown user returns Cloudflare's native `404`.

See [06 · Usage](06-usage.md) for the full link format and per-client import.
