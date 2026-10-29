# subflow

Multi-server sing-box management with an independent native Go node agent,
a TypeScript Cloudflare control plane, and one subscription per user.

```text
Administrator / client -> Cloudflare Pages -> central Worker -> D1
                                                |
                     Bandwagon API <------------+<---- Go agents on all VPSes
                                                           |
                                                        sing-box
```

Ordinary users share one quota across authorized servers. The `admin` identity
has no personal usage ledger: its subscription displays Bandwagon fleet usage
and remaining traffic. Each VPS reserves credit centrally and enforces it locally.
Client configuration generation remains at the edge. sing-box is a separate
upstream executable, not an embedded or reimplemented proxy core.

Start with [central management and domain setup](docs/08-central-management.md).
The existing single-VPS private-API gateway remains available without a `CENTRAL`
service binding, but username-only legacy links are not recommended for new use.

## Runtime and development

- **VPS:** Linux amd64 or arm64 with systemd. Install/update operations need root.
  The Go application does not require a Python or Node.js runtime.
- **Gateway deployment:** Node.js 24 and the repository's pinned Wrangler
  development dependency. Node.js is deployment tooling, not an API dependency.
- **Development:** Go 1.25+ and Node.js 24. The Go binary embeds its defaults and
  timezone database.
- **External components:** sing-box; Cloudflare Pages, Workers and D1 for central
  management; an operator-provided SOCKS endpoint when WARP routing is enabled.
  Central agents connect outbound over HTTPS and do not need a management Tunnel.

The migration retains existing JSON data paths, `SUBFLOW_*` environment
variables and the `sf` / `s` entry points. Central subscriptions use new random
token links, not the legacy username-only URLs.
Read the [migration guide](docs/07-migration.md) before replacing an existing
installation.

## Build and validate

```bash
go mod download all
go test -race ./...
go vet ./...
go build -o subflow ./cmd/subflow

npm ci
npm run typecheck
npm test
npm run build
```

Run system-management integration tests only with their temporary directories
and fake command runners. Do not run the installer against a development
machine just to test a build.

## Install

The release bootstrap requires a published **`subflow-v*` application release**.
It cannot install the new application from an older sing-box-only release.

```bash
curl -fL https://raw.githubusercontent.com/arnozeng98/subflow/main/deploy/install.sh \
  -o subflow-install.sh
bash subflow-install.sh
```

Use `subflow help` for commands. `sf` opens deployment management and `s` opens
sing-box management. Deploy the central platform once using the manual GitHub
Actions workflow, then enroll each VPS. `sf deploy` is the separate standalone
Pages/Tunnel deployment path, not the multi-server control-plane installer.

## Repository layout

| Location | Responsibility |
| --- | --- |
| [cmd/subflow](cmd/subflow) | Application entry point and compatibility routing |
| [cmd/release](cmd/release) | Native release builder and checksummed archives |
| [internal/api](internal/api) | Authenticated, per-user raw data API |
| [internal/nodehost](internal/nodehost) | Independent node manager, accounting and central agent |
| [internal/deploy](internal/deploy) | Installation, services, updates and Cloudflare deployment |
| [internal/settings](internal/settings) | Typed configuration and literal env-file parsing |
| [internal/state](internal/state) | Atomic JSON persistence and cross-process locking |
| [cloudflare/functions](cloudflare/functions) | TypeScript Pages handler and generators |
| [cloudflare/central](cloudflare/central) | Workers API, transactional D1 quotas and Bandwagon collector |
| [cloudflare/admin](cloudflare/admin) | Central management UI |
| [configs](configs) | Embedded JSON defaults; no code-generation step |
| [contracts](contracts) | Raw API schema and shared compatibility fixtures |
| [deploy](deploy) | Minimal download/bootstrap shell |
| [docs](docs) | Architecture, deployment and migration documentation |

## Releases

Application tags use `subflow-v*`; sing-box kernel releases retain upstream
`v*` tags. These are separate products even though the artifacts share a
repository. Kernel builds do not overwrite the application's `latest` release
or delete application releases.

CI checks Go formatting, tests, race detection, vet, Linux builds, TypeScript
types, gateway tests, bundling, and the bootstrap. Application release jobs run
the checks again before packaging.

```bash
go run ./cmd/release -version subflow-v0.1.0 -out dist
```

This creates Linux amd64/arm64 archives plus `sha256sum.txt`; it does not
publish a release.

## Documentation

- [Architecture](docs/01-architecture.md)
- [VPS deployment](docs/02-vps-deployment.md)
- [Cloudflare deployment](docs/03-cloudflare-deployment.md)
- [Secrets and configuration](docs/04-secrets-and-config.md)
- [Templates and rules](docs/05-templates-and-rules.md)
- [Subscription usage](docs/06-usage.md)
- [Migration and compatibility](docs/07-migration.md)
- [Central management, domain and Actions setup](docs/08-central-management.md)
- [Security boundaries](SECURITY.md)
- [Third-party provenance](THIRD_PARTY.md)
