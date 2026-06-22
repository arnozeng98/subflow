# 05 · Templates & rules

Generated configurations are **complete** and stay **current** because their
rules are referenced from official, continuously-maintained sources using each
client's native remote-rule mechanism. subflow does not re-host rule data.

## Official sources

| Format | Groups / skeleton | Rules referenced from |
| --- | --- | --- |
| Clash / Mihomo | ACL4SSR-style proxy groups | [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) `rule-providers` |
| sing-box | official route/dns layout | [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) + [sing-geoip](https://github.com/SagerNet/sing-geoip) remote `rule_set` |
| Surge | policy groups | [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) `RULE-SET` |
| Quantumult X | policy + filters | blackmatrix7 `filter_remote` |
| Shadowrocket | base64 URI list | client-side / remote rule file |
| Universal | base64 URI list | n/a |

Because these are referenced by URL, the client fetches and refreshes them
directly from upstream — the delivered config is always backed by the latest
rules without any action from subflow.

## How a config is built

1. The gateway normalizes the user's nodes ([protocol.js](../cloudflare/functions/_lib/protocol.js)).
2. The matching generator under [cloudflare/functions/_lib/templates/](../cloudflare/functions/_lib/templates)
   builds the proxies/outbounds, the proxy/policy groups, and the rule references.
3. The result is returned with the correct content type.

sing-box output is validated with a JSON round-trip before it is returned, so the
gateway never emits a config the client cannot parse.

## Caching

When a base-template override URL is configured (see below), the fetched text is
cached in the Cloudflare **Cache API** (`caches.default`) for
`TEMPLATE_CACHE_TTL_SECONDS` (default 6h). The first request after expiry refetches;
others are served from cache. A fetch failure is non-fatal — the built-in complete
skeleton is used instead, so a flaky source never breaks subscriptions.

The remote *rule sources* themselves are fetched by the **client**, not by
subflow, so they are not subject to this cache.

## Overriding sources

All sources are environment variables (see
[04 · Secrets & configuration](04-secrets-and-config.md)). Common reasons to override:

- **Pin a mirror** (e.g. a faster CDN or a self-hosted copy):
  set `SUBFLOW_CLASH_RULES_BASE`, `SUBFLOW_SINGBOX_GEOSITE_BASE`, etc.
- **Pin a version** instead of `@release` / `@master` / `rule-set` (latest).
- **Use a fully custom base template**: set `SUBFLOW_<FORMAT>_TEMPLATE_URL`. For
  Clash, the template may contain the markers `#SUBFLOW_PROXIES`,
  `#SUBFLOW_GROUPS`, `#SUBFLOW_PROVIDERS`, `#SUBFLOW_RULES`, which are replaced
  with the generated sections; otherwise the built-in skeleton is used. For
  sing-box, the override JSON's `outbounds` array is replaced with the generated
  outbounds.

## Defaults

The default source bases are defined once in
[cloudflare/functions/_lib/constants.js](../cloudflare/functions/_lib/constants.js) (`RULE_SOURCES`) and
are all overridable via env, keeping configuration external.
