# 01 · Architecture

subflow has two deployment targets: managed VPSes and a Cloudflare central
platform. The central platform consists of a Pages frontend/subscription router,
a service-bound Worker and a persistent D1 database. The Worker owns user policy,
atomic global quota reservations, agent synchronization and Bandwagon collection.
See [central management](08-central-management.md) for the complete data flow.

## VPS: native Go application

The [application entry point](../cmd/subflow/main.go) routes commands to:

- [Node manager](../internal/nodehost): protocol configuration, users, quotas, routing
  and sing-box integration.
- [Private API](../internal/api): authenticated per-user JSON projection.
- [Deployment](../internal/deploy): local installation, services, kernel
  lifecycle, Cloudflare provisioning, upgrades and uninstall.

Commands share [typed settings](../internal/settings) and
[JSON persistence](../internal/state). The latter uses the existing manager
lock file, keeps full read-modify-write operations inside the lock, preserves
integer precision, writes temporary files, flushes them, and atomically replaces
the destination. On Linux the containing directory is also flushed.

sing-box remains a separate executable. Configuration checks and service
operations cross an explicit process boundary; Go does not execute the old
Bash or Python business implementations.

## Cloudflare: TypeScript gateway

With a `CENTRAL` service binding, Pages forwards administration, agent and
random-token subscription requests to the central Worker. The Worker renders
client formats from recently acknowledged node projections in D1, rather than
waiting for live replies from every VPS. Vendor usage and user usage are separate
ledgers; `admin` is never counted as an individual traffic consumer.

The following private API path remains available in **standalone mode only**:

The [Pages handler](../cloudflare/functions/[user].ts) orchestrates:

1. Username validation and environment resolution.
2. Authenticated raw-data retrieval from the VPS.
3. Protocol detection and normalized node construction.
4. Format negotiation.
5. Clash, sing-box, Surge, Quantumult X, Shadowrocket or universal generation.

The existing HTTP boundary is intentional: client subscription generation
remains at the edge. The Go manager also retains the legacy local export
commands for operators; the private HTTP API itself never renders client
configurations. There is no second competing subscription HTTP API.

## Persistent compatibility

The following files remain the on-disk interface:

- `/etc/sing-box/config.json`
- `/etc/sing-box-manager/user-manager.json`
- `/etc/sing-box-manager/meta.json`

Defaults now come from [embedded JSON](../configs/defaults.json). No Python
generator or handwritten subset-YAML parser is needed. Environment overrides
remain supported.

The versioned raw response contains `schema_version: 1`, `username`, `enabled`, `usage`, `inbounds`,
`meta`, `public_ip`, and `ws_domains`. Its contract is captured in the
[JSON Schema](../contracts/raw.schema.json) and
[shared fixture](../contracts/fixtures/raw-alice.json). The endpoint remains
`GET /internal/raw/<username>`.

Missing users and unavailable user nodes return `404`. Corrupt or unreadable
state now produces a logged `503`, rather than being silently treated as an
empty user database. `/healthz` is authenticated, just like the original
implementation; old documentation describing it as public was inaccurate.

## Packaging

The repository contains source, tests, configuration and deployment resources.
The [Go release builder](../cmd/release) creates a native binary plus gateway
sources and pinned npm manifests in each application archive.

Application releases use `subflow-v*`; kernel releases use upstream `v*`
versions and are not marked as the repository's latest application release.
Neither release workflow deletes unrelated historical releases.
