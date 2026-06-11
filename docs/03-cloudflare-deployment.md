# 03 · Cloudflare deployment

The Cloudflare Pages project is the public gateway and the place where all client
configurations are generated.

## Prerequisites

- A Cloudflare account.
- This repository pushed to GitHub (or connected directly).
- The VPS data API reachable over HTTPS (see [02 · VPS deployment](02-vps-deployment.md)).
- The Bearer token printed by the VPS installer.

## Option A — Automated from the VPS installer (recommended)

If you have already installed the VPS data API, you can deploy the Cloudflare
Pages gateway from the same machine with **one command** — no fork and no GitHub
token required. It uses Wrangler **Direct Upload**, sending the `functions/`
directory that the installer already downloaded.

```bash
sf deploy        # or: run install.sh and pick "VPS API + Cloudflare 自动部署"
```

The wizard prompts (each with an explanation and default) for:

- **Cloudflare API Token** — create one at *My Profile → API Tokens* with a
   **Custom token**. Minimum permissions for this script are:
   - *Account → Cloudflare Pages → Edit*
   - *Zone → DNS → Edit*
   - *Zone → Zone → Read* (needed to look up the zone id by domain name)

   Recommended resources:
   - *Account resources* → **Include** → your target account
   - *Zone resources* → **Include** → your root domain zone (or all zones if you
      want to reuse the token)

   The token is used only at runtime and is never written to disk.
- **Account ID** — *Workers & Pages → Account ID* (right sidebar).
- **Root domain** — e.g. `example.com` (must be a zone in this account).
- **Subscription host** — default `subflow.<root>`; the public URL clients use.
- **API host** — default `api.<subscription host>`; A record → VPS origin,
  created **grey-cloud (proxied=false)** so Pages can reach the origin.
- **Origin IP** — defaults to the auto-detected public IP of this VPS.
- **Project name** — default `subflow`.

If you prefer to set the token manually in the dashboard, the same permission
set above applies: one token is enough to create the Pages project, attach the
domain, and manage the DNS record.

It then verifies the token, ensures the Pages project exists, uploads the assets,
sets the `VPS_API_BASE_URL` / `VPS_API_BEARER_TOKEN` secrets, creates the DNS
record, attaches the custom domain, and prints the subscription URL.

Requires Node.js 18+ / `npx` on the VPS; the wizard offers to install Node 20 via
NodeSource if missing.

## Option B — Dashboard

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

## Option C — Wrangler CLI

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
