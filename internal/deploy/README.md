# Native host deployment

`Run(ctx, args, in, out, errOut)` implements the deployment menu and commands.
`RunWithOptions` additionally injects the HTTP client, external-executable runner,
API readiness probe, asset path, architecture and host filesystem root for tests.
The root binary sets `deploy.ManagerRun = nodehost.Run` to share interactive
input when selecting the manager from the deployment menu.
`RootDir` redirects files only; tests **must also inject `Execute`**. Never use a
staging root with the production executor.

## Commands

```text
subflow install --yes --assets /path/to/release --set SUBFLOW_PUBLIC_IP=example.com
subflow install --with-kernel --with-cloudflare
subflow edit --set SUBFLOW_LISTEN_PORT=28080
subflow info [--show-secrets]
subflow status|start|stop|restart|enable|disable [--service sync|maintenance|cloudflared]
subflow logs [--follow] [--lines 100]
subflow update --version subflow-v1.0.0
subflow kernel install|update [--version v1.12.0]
subflow kernel info|status|start|stop|restart|enable|disable|logs|uninstall
subflow time-sync
subflow uninstall --yes
subflow deploy --yes --account ACCOUNT_ID --zone example.com --project subflow
```

Use `CLOUDFLARE_API_TOKEN` rather than command-line credentials. Optional
`--sub-host`, `--api-host`, `--assets` select deployment details. Every mutating
command accepts `--dry-run`, which performs no network, process or filesystem
mutations. Interactive `sf` opens this menu; `s` and the manager menu option enter
the native manager via the installed Go executable.

## Release layout

Both application architectures use this tar root:

```text
subflow
package.json
package-lock.json
tsconfig.json
cloudflare/build.ts
cloudflare/wrangler.toml
cloudflare/functions/**
cloudflare/tests/**          (included by the TypeScript typecheck)
```

Other Cloudflare source files, tests and fixtures may also be included.
Application archives are `subflow-linux-{amd64,arm64}.tar.gz`; tags use
`subflow-v*` and GitHub's latest release. The mandatory `sha256sum.txt` names each
archive exactly. Kernel archives are `sing-box-linux-{amd64,arm64}.tar.gz` with
`sing-box` at the tar root, under upstream `v*` tags not marked latest. Kernel
discovery enumerates releases and checks matching assets.

The Go executable goes to `/usr/local/bin/subflow`; `s`/`sf` are symlinks.
Manifests remain at `/opt/subflow`; source remains at `/opt/subflow/cloudflare`.
`--assets` accepts either the release root or its Cloudflare child, also exposed
through `Options.AssetsDir` / `SUBFLOW_ASSETS_DIR`.

Cloudflare deploy uses Node.js 24+ and npm, `npm ci --ignore-scripts`, the
release's prebuilt `cloudflare/dist` (or `npm run build` when absent), then the
exact project-pinned Wrangler through `node`. No
unversioned npx download, shell installer, legacy Bash or Python is invoked.
Existing authenticated Wrangler credentials are isolated from the supplied token.

The bootstrap supports either curl or wget, permits HTTPS downloads and HTTPS
redirects only, and validates the release checksum before running anything.
On Debian-family hosts, root can authorize missing bootstrap packages (tar, gzip,
coreutils, mawk, a downloader, CA certificates) with the prompt or `--yes`.
It removes only its exclusively created `.subflow-bootstrap.<pid>` directory,
including after failed downloads and after the native installer returns, while
preserving the native installer's exit status. It never adopts an existing
directory with that name.

## Service and recovery behavior

Linux with systemd is required for host operations. Debian 12/13 (and apt-based
derivatives) automatically install missing systemd, CA certificates, and chrony
when relevant, after a confirmation or explicit `--yes`. Apt failures stop the
operation before runtime replacement. Node is never required by the Go API.
Cloudflare operations offer an official SHA-256-verified Node 24 bundle if
Node/npm is absent or too old; it lives in a versioned `/opt/subflow/node`
directory and does not replace the system Node installation.
Non-systemd/OpenRC systems
receive explicit errors rather than partially installed shell-based services.
Native services run `subflow serve`, periodic
`subflow sync` (three minutes, preserving the legacy cadence), and
`subflow maintenance` (04:47 in the host's local timezone).
Maintenance retains the latest 10 MiB of the kernel access log and refreshes the
cached kernel release tag. Time synchronization uses an already installed chrony.

Updates stage and SHA-256-verify releases. Kernels additionally must report
`with_v2ray_api` and accept the existing configuration with `sing-box check`.
Managed files, modes, symlinks and prior service enabled/running states are backed
up before replacement. Failed activation or API readiness restores the old
runtime; failed recovery leaves named adjacent backups and an explicit error.
The API readiness request uses the exact `Bearer <configured token>` header.
Uninstall removes only enumerated runtime files and leaves environment,
configuration, assets, user databases and logs. If the kernel remains installed,
the shared manager binary and aliases remain available.

Cloudflare preflight checks token activity, account/zone ownership, effective
zone scopes and Pages/Tunnel/DNS access. Where allowed, it also checks token
policies; write API calls enforce edit scopes when token-policy introspection is
unavailable. Existing tunnel ingress, DNS record metadata and unrelated Pages
variables are preserved. New tunnel credentials are mode 0600, and the isolated
`subflow-cloudflared.service` never uninstalls an unrelated cloudflared service.
Downloaded cloudflared binaries require a GitHub SHA-256 release-asset digest.

Cloudflare is not a distributed transaction: DNS/tunnel changes and local service
files are rolled back on failure, but an already-published Pages deployment and
overwritten encrypted project secrets cannot always be restored through the API.
Such failures are explicit and safe to retry using the retained local API token.
Live Cloudflare authorization/domain activation and actual systemd startup still
need validation on a disposable host with operator credentials; automated tests
use injected APIs/processes and never mutate real services.
