# 03 · Cloudflare deployment

For the new multi-server platform, use
[central management and GitHub Actions setup](08-central-management.md).
Deploy it once, then register VPS agents. The rest of this page describes the
optional **standalone, single-VPS** Pages/Tunnel deployment.

The TypeScript gateway still runs on Cloudflare Pages. Subscription generation
has not moved to the VPS.

## Requirements

- A Cloudflare account and a domain zone in that account for automatic setup.
- The VPS API token and a reachable API origin.
- Node.js 24 for Wrangler tooling, not for the Go API.
- The repository's locked npm dependencies; do not install an unpinned global
  Wrangler version.

## Automatic deployment

```bash
sf deploy
```

Use a custom Cloudflare API token with these permissions:

- Account: Cloudflare Pages / Edit
- Account: Cloudflare Tunnel / Edit
- Zone: DNS / Edit
- Zone: Zone / Read

Scope it to the selected account and domain zone. Provisioning sets the private
API URL and bearer token, deploys the gateway, configures a named Tunnel and DNS,
and attaches the subscription hostname. Cloudflare credentials must never be
included in a public Pages asset directory.

The API listens locally by default. A Tunnel connects outbound, so it does not
require a second process to bind the sing-box port 443.

## Manual build and deployment

Run from the repository or unpacked application release root:

```bash
npm ci
npm run typecheck
npm test
npm run build
npx --no-install wrangler pages secret put VPS_API_BASE_URL --cwd cloudflare
npx --no-install wrangler pages secret put VPS_API_BEARER_TOKEN --cwd cloudflare
npx --no-install wrangler pages deploy dist --cwd cloudflare
```

The build produces `cloudflare/dist` containing `_worker.js`, `_routes.json`,
and `404.html`. Only that directory is public. The advanced-mode worker embeds
the Pages routing behavior and preserves unknown-user `404` responses.

Do not upload the repository root, source files, tests, env files or credentials
as static assets.

## Git-connected Pages

Use these build settings when connecting the repository:

- Root directory: repository root.
- Build command: `npm ci && npm run build`.
- Build output directory: `cloudflare/dist`.
- Node.js version: 24.

Set `VPS_API_BASE_URL` and `VPS_API_BEARER_TOKEN` as encrypted variables for the
correct deployment environment. Preview deployments require their own
appropriately scoped origin and token.

## Local development

```bash
npm ci
npm run build
cp cloudflare/deploy/.dev.vars.example cloudflare/.dev.vars
# Set test-only origin/token values in cloudflare/.dev.vars.
npx --no-install wrangler pages dev cloudflare/dist --config cloudflare/wrangler.toml
```

Use only test users and credentials. Never commit `.dev.vars`.

## Verify

After deploying, import a real test user's subscription in the intended client:

```text
https://sub.example.com/alice?format=clash
https://sub.example.com/alice?format=singbox
https://sub.example.com/alice?format=surge
https://sub.example.com/alice?format=quantumultx
https://sub.example.com/alice?format=shadowrocket
https://sub.example.com/alice?format=universal
```

Check unknown/disabled users, traffic headers, and upstream failure behavior as
well as successful downloads. JSON/YAML syntax alone does not prove a specific
client version supports every emitted protocol option.
