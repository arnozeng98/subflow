# Third-party sources and redistribution

The root [LICENSE](LICENSE) applies to subflow's own code, not to upstream
components. This document records engineering provenance; it is not legal advice
or a warranty of non-infringement.

## Historical manager

The original bundled Shell manager came from
[Tangfffyx/sing-box](https://github.com/Tangfffyx/sing-box). The remote project's
earlier provenance review recorded no explicit redistribution license for that
source. Public visibility alone does not grant redistribution rights.

The old Shell/Python implementation and the initial Go port that consulted it
are not included in this source tree or the new application packages.
The replacement [node manager](internal/nodehost) was implemented by a separate
agent under explicit input restrictions: no old manager, no initial Go port,
no source repository, and no previous manager-agent history. Its actual permitted
inputs and validation sources are recorded in
[PROVENANCE.md](internal/nodehost/PROVENANCE.md).

The integrating agent had seen prior implementation code. The input restriction
is an engineering isolation measure, not a representation that the whole project
has been legally certified as clean-room work. New development must preserve the
input record and must not reintroduce restricted source.

Rewriting repository references does not remove external clones, forks, pull
request refs or hosting caches. Old releases and retained remote references must
be handled separately; do not advertise history rewriting as erasing all copies.

## Distributed runtime dependencies

| Component | Source | License / handling |
| --- | --- | --- |
| sing-box | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | GPL-3.0-or-later; separate executable |
| Go runtime | [golang/go](https://github.com/golang/go) | BSD-style; license included in app archive |
| flock | [gofrs/flock](https://github.com/gofrs/flock) | BSD-3-Clause; module license included |
| x/sys | [golang/sys](https://github.com/golang/sys) | BSD-3-Clause; module license included |

The application archive contains its Go source, dependency manifests, license
texts and gateway source. Kernel releases must include the corresponding
upstream source archive, upstream LICENSE, BUILD_INFO.json and SHA-256 manifest.
The build uses upstream default tags without `with_naive_outbound` (libcronet.so
is not bundled), and adds `with_v2ray_api`.

## Downloaded tooling and external services

Wrangler and the TypeScript build/test tooling use the exact versions in
[package-lock.json](package-lock.json). Their packages retain upstream license
notices; node_modules is not redistributed in application archives.
cloudflared is a separately downloaded Apache-2.0 component with release-digest
verification. Node.js is separately downloaded with official checksum verification.

Cloudflare Pages, Workers and D1 are hosted services, not bundled software.
The Bandwagon adapter calls KiwiVM's service-info API; no vendor code is copied.
The WARP option connects to an operator-provided SOCKS endpoint; no external
WARP installer is copied or executed.

## Client rule sources

Generated configurations reference, rather than embed, rule data from
SagerNet/sing-geosite, SagerNet/sing-geoip, Loyalsoldier/clash-rules and
blackmatrix7/ios_rule_script. Their own licenses and availability apply.
See [templates and rules](docs/05-templates-and-rules.md).
