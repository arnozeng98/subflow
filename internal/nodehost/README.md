# Native node host

Independent Go implementation; see [PROVENANCE.md](PROVENANCE.md) for inputs
and validation boundaries.

## Integration

The parent command should call:

```go
nodehost.Run(ctx, args, os.Stdin, os.Stdout, os.Stderr)
```

Tests/embedding use:

```go
nodehost.RunWithOptions(ctx, args, in, out, errOut, nodehost.Options{
    Config: cfg,
    Command: command,
    Stats: stats,
    Now: now,
    HTTPClient: client,
})
```

`Command` accepts `(context.Context, string, ...string) ([]byte, error)`;
`Stats` accepts `(context.Context, string) ([]nodehost.Stat, error)`.
`Stat` exposes `Name string` and `Value int64`.

Deployment callbacks may invoke `config init` (equivalent to `init`) and
`maintenance` / `maintenance once` / `maintenance run` (one accounting and
quota/expiration enforcement pass). These entry points receive the command
arguments **after** any parent dispatcher prefix. Continuous supervision uses
`agent run`; no separate maintenance timer is necessary when that loop runs.
`config init` preserves existing native configuration, creates admin when absent,
validates, and restarts sing-box; it does not create any inbound or choose ports.
The parent must load its environment file before calling `Run`, or supply an
explicit `Options.Config`.

Run `subflow agent run` under a root-owned systemd service with restart-on-failure,
after sing-box/network readiness. The loop also enforces standalone quotas when
not enrolled, without attempting central synchronization. Service
integration should **not** independently restart sing-box during an accounting
transaction. Use the nodehost lifecycle commands instead.
Graceful agent cancellation performs a final sample and stops sing-box. The
systemd unit should restart the agent promptly after abnormal termination; a
SIGKILL cannot run graceful accounting cleanup.

For an external kernel/binary upgrade, call `system prepare-restart` **before**
any `systemctl stop`, file replacement, or kernel operation. It durably accounts
traffic, stops the core, and holds the agent's restart/sync application paths.
Perform the external operation, then call `system start` (or `system restart`).
That command releases the hold, starts a restricted runtime, probes its stats API,
and only then restores ordinary users with a valid remaining grant. Protocol/TLS
edits can be validated and saved while held without starting the core. The aliases
`service ACTION` and `node ACTION ...` map to `system` and `protocol`.
Root `sync` runs local accounting/maintenance until a nonempty enrolled
`server_id` exists, then runs `agent sync`. This supports the same three-minute
sync timer in standalone and central modes, including empty or pending
`.central` files without spurious “not enrolled” errors.

Required runtime:

- Debian/systemd; installed `sing-box` and `systemctl` on a trusted root PATH.
- The verified integration target is sing-box 1.14.4, including AnyTLS and route
  actions. ACME requires its `with_acme` build tag.
- A **trusted sing-box build containing `with_v2ray_api`**. Official default
  1.12.0 binaries omit this feature; configuration validation intentionally fails
  rather than silently permitting unmetered ordinary users.
- Go 1.25+ to compile the stdlib HTTP/2 cleartext client.
- Statistics listens only on `127.0.0.1:10085`; never publish this endpoint.

No installer is run. WARP integration uses an already provisioned SOCKS endpoint.
`export --name NAME --format clash` emits native JSON-compatible YAML containing
`proxies`, a selection group, and a matching default rule for current Mihomo.
It supports all eight managed protocols, including AnyTLS, TUIC, Reality and
multi-user Shadowsocks 2022 (server PSK plus user PSK). Older Clash clients may
not support these protocols. Credential aliases receive distinct proxy names;
only the requested user's permitted nodes are included. WebSocket domains/path,
TLS server name/ALPN and public Reality parameters are projected explicitly.
Certificate verification remains enabled; install production certificates or
configure client trust separately for bootstrap certificates. Server private
keys and ACME tokens are never exported. Unknown formats, protocols and
unsupported transports fail explicitly, without partial Clash output.
`--format json` remains the safe Raw contract; `--format uri` remains URI output.
WebSocket inbounds begin as plain WS; native TLS can be added with either
production certificate command below, or terminated by a separate reverse proxy.
New native TLS inbounds initially have one-year self-signed bootstrap certificates.
**These are not complete production TLS. Never disable client validation.**

For public TLS, configure native sing-box ACME DNS-01:

```text
protocol acme --tag TAG --domain node.example.com --email admin@example.com --token-file FILE
```

The Cloudflare token must grant the required zone DNS edit/read permissions.
It is imported into mode-0600 config/journal files, never Raw payloads; ACME data
is held beneath `MetaPath + ".acme"/TAG` with a mode-0700 directory. Both HTTP and
TLS-ALPN challenges are disabled. The core obtains and automatically renews the
certificate. `--acme-mode auto` selects inline `tls.acme` before 1.14 and native
`tls.certificate_provider` from 1.14 onward; the latter is verified against the
actual 1.14.4 kernel. Inline ACME is deprecated in 1.14 and removed in 1.16.

Externally issued certificates, including a fallback for unavailable ACME support,
can be imported without changing protocol credentials:

```text
protocol certificate-import --tag TAG --server-name node.example.com --cert-file chain.pem --key-file key.pem
```

Import checks matching private key, validity dates, and hostname, then stores the
PEM chain/key atomically with the configuration. Repeat after external renewal;
the importing operator remains responsible for the chain's client trust. Production
TLS is never silently replaced by a self-signed certificate on a hostname update.
`protocol certificate --tag TAG` exports only inline public PEM material.
Every inbound and relay/WARP endpoint requires an explicit `--port` (1–65535);
there are no implicit per-protocol ports. Inbounds listen on `::`. The default WS
path is `/<tag>`; the default TLS/Reality server name is `www.microsoft.com`, and
Reality's handshake target uses port 443. Production certificate commands require
the intended hostname rather than treating the bootstrap default as a public CA
certificate.

## Files and policy

All principal locations come from `settings.Config`. Additional mode-0600 files:

- `UserDBPath + ".central"`: enrollment identity/token, server credential,
  sequence, exact pending request bytes, durable response, applied revision.
- `UserDBPath + ".journal"`: rollback snapshots and candidate accounting state.
- `MetaPath + ".routing"`: SOCKS relay/WARP endpoints and local rule-set references.
- `ConfigPath + ".candidate"`: short-lived validation candidate.

The root config remains sing-box JSON. The database keeps `{ "users": { ... } }`
with additional counter, archive, and recovery fields. Metadata remains keyed by
inbound tag, with public Reality key and native protocol name. Private credentials
remain in mode-0600 node state. Raw exports are explicit whitelists, never root
config copies. The Shadowsocks server PSK is intentionally present in an SS
subscription; Reality/TLS private keys and certificate paths are never present.

Authenticated allow rules include both inbound and `auth_user`. Every generated
route ends in `reject`. Disabled/unauthorized credentials are removed from inbound
authentication. Empty SOCKS/SS user sets get an unexported random sentinel to
prevent empty-user anonymous/single-user fallback. Admin can be centrally
disabled, but never accrues usage, receives a quota, or appears in reports.

Standalone `quota-bytes=0` means unlimited; managed `quota_bytes=0` means exhausted.
Central `grant_bytes` is the cumulative ceiling for one server/user/period, never
an increment. Managed enrollment locks out all local user/quota and raw-config
changes, including while enrollment is pending. Local protocols and routing remain
editable and are included in the next newly constructed sync request.

## Standalone calendar and compatibility

`--reset-day 0` selects manual resets. Days 1–31 reset at local midnight on that
day, clamped to the month's last valid day; 32 explicitly means the last day.
The timezone is `settings.Config.BusinessTimezone` / `SUBFLOW_BUSINESS_TIMEZONE`
(system local timezone when unset). Maintenance catches up to the latest missed
scheduled reset once, without accumulating unused monthly allowances. Calendar
resets never apply to admin or centrally managed periods.

`user renew --days N` extends from the later of now and the existing expiration
using local calendar days; `--expires UNIX` sets an explicit expiry. Renewal
preserves counters unless `--reset-usage` is requested. `user correct` sets
ordinary standalone uplink/downlink totals and clears any older additive manual
offset, avoiding double-counting in API consumers. Imported `manual_added_bytes`
retains its additive standalone meaning. `user usage` reads current totals and
the next reset time. Reset,
renewal and correction preserve all authentication credentials.

The user database continues to persist public compatibility fields `enabled`,
fractional `quota_gb`, `used_up_bytes`, `used_down_bytes`, `manual_added_bytes`,
`reset_day`, `last_reset_period`, and `expire_at`. Import accepts numeric/string
legacy scalar fields. Date-only expiry is preserved for the API and enforced
through the end of that date in the local business timezone; Unix seconds and
RFC3339 are also supported. The parent usage decoder/schema must accept fractional
`quota_gb` and `reset_day` through 32.

Existing public-contract named inbound credentials, additional aliases, SOCKS
login names, UUIDs/passwords, and server TLS fields are hydrated without rotation.
Counters use each preserved authentication identity, not an assumed tag prefix.
Missing per-user node permissions are derived from those existing records.
Anonymous/unnamed credentials are not silently adopted as named subscriptions.
Enrollment is explicit takeover: standalone balances are not reported as globally
issued grants, and the first central period begins only after a central response.

## Accounting, retries, recovery

The agent samples every five seconds and synchronizes approximately every minute.
Central HTTP requests run outside the file lock and outside the sampling loop,
so a slow/disconnected central service does not block local accounting.
Only observed cumulative uplink/downlink differences are added; counter resets
and process identity changes are detected. Queries never reset remote counters.
Counters are committed before configuration changes, sampled again after initial
validation, and preserved through rollback. The lock covers each transaction.

There is **no byte-perfect cutoff claim**. Overshoot depends on traffic rate, the
sampling interval, RPC latency and service-stop latency. sing-box exposes no
atomic drain-plus-counter-snapshot operation, so traffic arriving between the last
sample and process stop, or lost in an unexpected runtime crash, is not precisely
recoverable. No measured counters are fabricated to hide this limitation.

On unavailable/malformed statistics, nodehost logs an explicit error, stops
sing-box, and quarantines the affected ordinary user-periods. Interrupted/failed
transactions and unexpected runtime restarts likewise quarantine potentially
unmetered periods. A restricted/admin-only runtime can resume supervision, but
restoring the stats API alone **does not reopen quarantined ordinary periods**.
A central-authorized new period (or standalone `user reset`) is required. This
conservative fail-closed policy can sacrifice availability, but does not silently
reissue an uncertain remaining grant. Root state corruption/disk loss is not
recoverable accounting; stop traffic and restore from a trusted backup.

The `.central` file persists the generated enrollment credential and one-time
token **before** the enrollment request. Lost replies reuse both. Spent enrollment
tokens are removed after acknowledgement. Central URLs must be HTTPS origins;
redirects are never followed and HTTP error bodies/transport details are redacted.

Sync requests are stored as exact base64-encoded bytes so pretty-printing the state
file cannot alter a retry's digest. Responses are durably saved before application.
Only a committed configuration advances `applied_revision`. Initial sync reports
are empty until a user-period has actually been centrally granted. Reports never
include admin. Old-period cumulative counters are archived across rollovers and
retained until a successful sync acknowledges their final values; disabled and
absent users remain non-serving report tombstones. Central must accept multiple
previously granted periods and deduplicate by username + period.
The integrated parent wire contract starts ordinary granted periods at 1 and
caps numeric values at 1,000,000,000,000,000. Reports are round-robin batched at
128 records so retained old periods do not permanently exceed its request limit.
Inventory and simultaneously exported payload owners are each limited to 128.
The latter cannot safely be paginated while central replaces the server's entire
payload cache on each sync; larger per-node assignments require a parent contract
change rather than silently dropping subscriptions.

## Validation

```text
go test ./internal/nodehost
go vet ./internal/nodehost
```

Set `NODEHOST_TEST_SINGBOX` to an installed, SHA-256-verified sing-box binary for
optional protocol, live SOCKS, native ACME configuration and actual gRPC traffic
tests. Feature-aware tests exercise native `with_acme` / `with_v2ray_api` support.
The 1.14.4 target passed actual DNS-01 configuration checking (without issuance)
and live per-user uplink/downlink accounting through the native gRPC client.

`TestAgentCentralIntegration` is opt-in. Set `SUBFLOW_TEST_CENTRAL_URL`,
`SUBFLOW_TEST_ENROLLMENT_TOKEN`, and optionally `SUBFLOW_TEST_USERNAME` (default
`alice`). Seed a fresh enabled server/token, enabled admin plus the ordinary user,
permissions `["*"]` or `["integration"]`, ordinary period ≥1, no expired account,
and at least 64 MiB available quota. Each run needs a fresh enrollment token.
The test makes one enrollment and two syncs using fake core commands and locally
generated credentials. Its test-only HTTPS-origin rewrite permits loopback HTTP
or the explicitly authorized WSL relay `172.30.48.1`; production HTTPS enforcement
is unchanged. `.central.server_id` is a top-level string, and only a nonempty
value proves enrollment.

Tests create/clean scratch directories beneath the package, not system temporary
directories. The verified 1.14.4 binary is retained in ignored `.work` for the
parent's deployment validation; build caches may be removed independently.
