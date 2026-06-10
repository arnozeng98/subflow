# 06 · Usage

## Subscription link

```
https://<your-pages-domain>/<username>[?format=<format>]
```

- `<username>` matches `^[A-Za-z0-9_-]{1,64}$`. It maps to the upstream business
  user (the part after `@` in `<node>@<username>` entries).
- `?format=` is optional. When omitted, the format is inferred from the client's
  `User-Agent`, falling back to `SUBFLOW_DEFAULT_FORMAT` (default `universal`).

Examples:

```
https://sub.example.com/alice
https://sub.example.com/alice?format=clash
https://sub.example.com/alice?format=singbox
https://sub.example.com/alice?format=surge
https://sub.example.com/alice?format=quantumultx
https://sub.example.com/alice?format=shadowrocket
https://sub.example.com/alice?format=universal
```

An unknown user returns `404`.

## Format reference

| `format` value | Output | Best for |
| --- | --- | --- |
| `clash` | Full Clash/Mihomo YAML | Clash Meta, Mihomo, Stash |
| `singbox` | Full sing-box JSON | sing-box |
| `surge` | Surge conf | Surge (iOS/macOS) |
| `quantumultx` (`qx`) | Quantumult X conf | Quantumult X |
| `shadowrocket` | base64 URI list | Shadowrocket |
| `universal` (`v2ray`, `base64`) | base64 URI list | V2RayN, NekoBox, generic |

Aliases such as `mihomo`, `clash.meta`, `sing-box`, `qx` are accepted.

### Protocol coverage per format

All protocols (VLESS-Reality, VLESS-WS, VMess-WS, AnyTLS, Shadowsocks, Trojan,
TUIC) are carried by `clash`, `singbox`, `shadowrocket`, and `universal`.

- **Surge** cannot express VLESS, so VLESS nodes are omitted from `surge` output.
- **Quantumult X** has no TUIC representation, so TUIC nodes are omitted from
  `quantumultx` output.

For a client that needs an omitted protocol, use `universal` or `clash`/`singbox`.

## Importing into clients

- **Clash Meta / Mihomo / Stash:** add the `?format=clash` link as a remote
  profile. Rule-providers update automatically.
- **sing-box:** use the `?format=singbox` link as a remote profile / config URL.
- **Surge:** *Profiles* → install from the `?format=surge` URL.
- **Quantumult X:** add the `?format=quantumultx` URL as a resource/subscription.
- **Shadowrocket:** add the base link as a subscription; Shadowrocket imports all
  protocols from the URI list.
- **V2RayN / NekoBox:** add the base link (or `?format=universal`) as a
  subscription.

## Traffic quota

For Shadowrocket, the response includes a `STATUS=` userinfo line derived from the
user's upstream quota, so the client can display remaining traffic when a quota is
configured upstream.

## Caching behavior

Subscription responses carry a `Cache-Control` derived from
`TEMPLATE_CACHE_TTL_SECONDS` (overridable via `RESPONSE_CACHE_CONTROL`). Clients
and Cloudflare's edge may cache for that window; force a refresh in the client to
fetch immediately after upstream changes.
