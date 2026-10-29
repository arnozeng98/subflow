# Independent nodehost provenance

This package was independently authored from the task's public behavioral
requirements and the explicitly permitted contracts listed below. This is an
engineering provenance record, **not legal certification** or an opinion on
copyright, licensing, or clean-room sufficiency.

## Repository inputs actually read

- `go.mod`
- `configs/defaults.json`
- `internal/settings/settings.go`
- `internal/state/state.go`
- `internal/api/payload.go` — public data contract only; no implementation copied
- `contracts/raw.schema.json`
- `cloudflare/central/sync.ts` — independently authored parent wire contract,
  explicitly permitted during integration follow-up
- `cloudflare/central/types.ts` — same follow-up permission

Permitted directory discovery listed filenames under `internal/settings`,
`internal/state`, and `contracts`; no other files from those listings were read.
`go.sum` was not manually read. The Go toolchain resolves the existing module
dependencies when compiling the permitted settings/state packages.

No source, test, documentation, history, or deleted code from `internal/manager`,
`vps`, or Tangfffyx/sing-box was read or used. No implementation work was
delegated. A session-agent metadata listing exposed agent names; no previous
manager agent's conversation, result, or implementation was accessed or used.
New files within `internal/nodehost` were subsequently read for debugging.
The scoped Clash/Mihomo export follow-up used only these new package files and
the parent's stated compatibility requirement. No migration document, legacy
export implementation, or additional external source was read.
Its complete package race suite and vet passed (74.8% statement coverage),
with the verified 1.14.4 kernel enabled. Export tests check all eight protocols,
TLS/Reality/WS/SS2022 mapping, aliases, permissions, IPv6, reserved names,
secret exclusion, and explicit rejection of unsupported formats/protocols.
These are Go projection tests, not a live Mihomo client interoperability test.

## Official sources consulted

The following official documentation pages were fetched using HTTPS. Initial
web-fetch requests were blocked by the tool's DNS-address filter; the same
public official pages were subsequently read through HTTPS curl. Search results
were supplementary; protocol decisions and checks use the official structures.

- https://sing-box.sagernet.org/configuration/experimental/v2ray-api/
- https://sing-box.sagernet.org/configuration/route/rule/
- https://sing-box.sagernet.org/configuration/route/rule_action/
- https://sing-box.sagernet.org/configuration/route/rule_set/
- https://sing-box.sagernet.org/configuration/inbound/vless/
- https://sing-box.sagernet.org/configuration/inbound/vmess/
- https://sing-box.sagernet.org/configuration/inbound/anytls/
- https://sing-box.sagernet.org/configuration/inbound/trojan/
- https://sing-box.sagernet.org/configuration/inbound/tuic/
- https://sing-box.sagernet.org/configuration/inbound/shadowsocks/
- https://sing-box.sagernet.org/configuration/inbound/socks/
- https://sing-box.sagernet.org/configuration/shared/tls/
- https://sing-box.sagernet.org/configuration/shared/dns01_challenge/
- https://sing-box.sagernet.org/configuration/shared/certificate-provider/acme/
- https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
- https://sing-box.sagernet.org/configuration/outbound/socks/
- https://pkg.go.dev/net/http — `Protocols.SetUnencryptedHTTP2`

Official documentation search excerpts also referenced:

- https://sing-box.sagernet.org/manual/proxy-protocol/shadowsocks/
- https://sing-box.sagernet.org/zh/configuration/experimental/v2ray-api/
- https://sing-box.sagernet.org/zh/configuration/route/rule/
- https://sing-box.sagernet.org/changelog/

## Runtime validation input

An official upstream **binary**, not upstream source, was downloaded for local
configuration and SOCKS authentication tests:

- https://github.com/SagerNet/sing-box/releases/download/v1.12.0/sing-box-1.12.0-linux-amd64.tar.gz
- Release asset metadata: https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.12.0
- Observed archive SHA-256:
  `f59b1253ae0143997cb46915af30d14a33431dcbd7e39edacfcde8d73050faaf`
- Reported version: sing-box 1.12.0, Go 1.24.5, linux/amd64.

The attempted upstream `sing-box-1.12.0-checksums.txt` URL did not exist, and no
published checksum was found in that release's asset metadata. The hash above
records the received artifact; it is **not** an independently authenticated
publisher checksum.

The official default release does not include `with_v2ray_api`. Therefore its
tests validate all eight inbound schemas, authorization/reject routing, the
all-disabled configuration, and live SOCKS authentication **without** the
experimental statistics block. Native V2Ray protobuf/gRPC transport is tested
separately against a real local HTTP/2 server. Deployment requires a trusted
sing-box build with `with_v2ray_api`; no automatic installer or third-party
installer is provided.

The approved WSL Ubuntu Go toolchain was used for focused tests and vet.
Scratch downloads, build caches, and test directories were confined to the new
package directory. Earlier scratch artifacts were removed; the later explicitly
requested 1.14.4 executable below is retained for parent deployment validation.

Validation result: `go test -count=1 -race -cover ./internal/nodehost` passed
(70.2% statement coverage), and `go vet ./internal/nodehost` passed. Optional
official-binary tests were enabled, including live authorized SOCKS forwarding
and rejection of disabled credentials.

Integration follow-up: the two newly permitted central TypeScript files above
were read for their wire constraints. Go wire-conformance tests cover the
1,000,000,000,000,000 numeric ceiling, period minimum 1, 128-record report
batching, first-sync empty reports, cumulative counters/grants, same-revision
grant increases, period rollover, and the previously issued revision ceiling.
`go test -count=1 -race -cover ./internal/nodehost` and vet passed again
(70.9% coverage; optional upstream-binary tests not rerun in this follow-up).
The actual CLI help was printed through `TestCLIHelpTranscript`.

## Explicitly authorized 1.14.4 target validation

The parent subsequently authorized inspection of this release's BUILD_INFO and
use of its SHA-256-verified Linux binary:

- Release metadata:
  https://api.github.com/repos/arnozeng98/subflow/releases/tags/v1.14.4
- Build record actually read:
  https://github.com/arnozeng98/subflow/releases/download/v1.14.4/BUILD_INFO.json
- Compiled executable:
  https://github.com/arnozeng98/subflow/releases/download/v1.14.4/sing-box-linux-amd64
- Expected GitHub asset digest, matched against the downloaded file before
  execution:
  `eae02234b6968cdecf4df10297f1abc6fb5b68b8997fd789e824f28ee4daa474`
- BUILD_INFO identifies SagerNet/sing-box v1.14.4, upstream commit
  `c005f35300ce76427dc285481ec5695f5b179cd2`, Go 1.25.5, with both `with_acme`
  and `with_v2ray_api`. The executable's version output agrees.

No repository source archive, earlier source archive, or sing-box source archive
was downloaded or read. No source code from this release was used.

The verified executable passed native ACME `certificate_provider` configuration
checking using a non-secret dummy token and no certificate issuance. A controlled
SOCKS connection sent and received 1,500 bytes; native HTTP/2 gRPC returned
1,500-byte per-user uplink and downlink counters, with no admin accounting.
The final focused race suite and vet passed with this binary enabled (73.1%
statement coverage), including standalone calendar/renewal/correction, protected
TLS configuration/import, upgrade holds/startup probes, and independently
constructed public-contract credential/ledger import fixtures.
The timer dispatch regression additionally verifies root `sync` accounting and
calendar enforcement before enrollment, fail-closed pending enrollment, and
unchanged central synchronization after enrollment.

The executable is retained at
`internal/nodehost/.work/sing-box-1.14.4` (ignored by Git) as requested by the
parent. The parent subsequently reported the optional actual Go-to-Workers/D1
integration test passing across two syncs, reaching revision 4. That external
integration fixture was not rerun during the scoped Clash export follow-up.
