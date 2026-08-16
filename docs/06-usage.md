# 06 · 使用说明

## 订阅链接

```
https://<your-pages-domain>/<username>[?format=<format>]
```

- `<username>` 必须匹配 `^[A-Za-z0-9_-]{1,64}$`。它对应上游业务用户
  （即 `<node>@<username>` 条目中 `@` 后面的部分）。
- `?format=` 为可选参数。省略时，会根据客户端的 `User-Agent` 推断格式；如果无法推断，
  则回退到 `SUBFLOW_DEFAULT_FORMAT`（默认值为 `universal`）。

示例：

```
https://sub.example.com/alice
https://sub.example.com/alice?format=clash
https://sub.example.com/alice?format=singbox
https://sub.example.com/alice?format=surge
https://sub.example.com/alice?format=quantumultx
https://sub.example.com/alice?format=shadowrocket
https://sub.example.com/alice?format=universal
```

用户不存在时返回 `404`。

## 格式参考

| `format` 值 | 输出 | 适用客户端 |
| --- | --- | --- |
| `clash` | 完整的 Clash/Mihomo YAML | Clash Meta, Mihomo, Stash |
| `singbox` | 完整的 sing-box JSON | sing-box |
| `surge` | Surge conf | Surge (iOS/macOS) |
| `quantumultx` (`qx`) | Quantumult X conf | Quantumult X |
| `shadowrocket` | base64 URI 列表 | Shadowrocket |
| `universal` (`v2ray`, `base64`) | base64 URI 列表 | V2RayN, NekoBox, 通用客户端 |

支持 `mihomo`、`clash.meta`、`sing-box`、`qx` 等别名。

### 各格式支持的协议

`clash`、`singbox`、`shadowrocket` 和 `universal` 支持全部协议（VLESS-Reality、
VLESS-WS、VMess-WS、AnyTLS、Shadowsocks、Trojan、TUIC）。

- **Surge** 无法表示 VLESS，因此 `surge` 输出会省略 VLESS 节点。
- **Quantumult X** 没有 TUIC 的表示方式，因此 `quantumultx` 输出会省略 TUIC 节点。

如果客户端需要已被省略的协议，请使用 `universal` 或 `clash`/`singbox`。

## 导入客户端

- **Clash Meta / Mihomo / Stash：** 将 `?format=clash` 链接添加为远程配置。
  规则提供程序会自动更新。
- **sing-box：** 将 `?format=singbox` 链接用作远程配置或配置 URL。
- **Surge：** 在“配置”中通过 `?format=surge` URL 安装。
- **Quantumult X：** 将 `?format=quantumultx` URL 添加为资源/订阅。
- **Shadowrocket：** 将基础链接添加为订阅；Shadowrocket 会从 URI 列表导入所有协议。
- **V2RayN / NekoBox：** 将基础链接（或 `?format=universal`）添加为订阅。

## 流量配额

上游配置配额或到期时间后，响应会携带标准的 `Subscription-Userinfo` HTTP 标头
（`upload`、`download`、`total`、`expire`）。支持此标头的客户端（Shadowrocket、
Clash Verge、Stash、sing-box）无需额外配置，即可显示原生流量计量信息
（自动格式化为 GiB/MiB/KiB）和到期日期。

## 缓存行为

订阅响应的 `Cache-Control` 由 `RESPONSE_CACHE_CONTROL` 控制，默认值为 `no-store`，
以避免浏览器或共享代理保存用户节点凭据。`TEMPLATE_CACHE_TTL_SECONDS` 只控制网关获取的
基础模板文本在 Cloudflare Cache API 中的缓存时间，不影响最终订阅响应。

除非已经充分理解凭据泄露风险，否则不要把 `RESPONSE_CACHE_CONTROL` 改为 `public` 或
包含 `s-maxage` 的策略。
