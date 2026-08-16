# 05 · 模板与规则

生成的配置是**完整的**，并且会保持**最新**，因为配置使用各客户端原生的远程规则机制，
引用由官方持续维护的规则源。subflow 不会重新托管规则数据。

## 官方来源

| 格式 | 策略组/配置骨架 | 规则引用来源 |
| --- | --- | --- |
| Clash / Mihomo | ACL4SSR 风格的代理组 | [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) `rule-providers` |
| sing-box | 官方 route/dns 布局 | [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) + [sing-geoip](https://github.com/SagerNet/sing-geoip) 远程 `rule_set` |
| Surge | 策略组 | [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) `RULE-SET` |
| Quantumult X | 策略和过滤器 | blackmatrix7 `filter_remote` |
| Shadowrocket | base64 URI 列表 | 客户端侧/远程规则文件 |
| Universal | base64 URI 列表 | 不适用 |

由于这些规则通过 URL 引用，客户端会直接从上游获取并刷新它们，因此无需 subflow 执行任何操作，
下发的配置便始终由最新规则提供支持。

## 配置的生成方式

1. 网关对用户节点进行规范化处理（[protocol.js](../cloudflare/functions/_lib/protocol.js)）。
2. [cloudflare/functions/_lib/templates/](../cloudflare/functions/_lib/templates) 下对应的生成器
   会生成 proxies/outbounds、代理组/策略组和规则引用。
3. 结果会以正确的内容类型返回。

sing-box 输出在返回前会通过 JSON 往返转换验证，因此网关绝不会下发客户端无法解析的配置。

## 缓存

配置基础模板覆盖 URL（见下文）后，获取到的文本会在 Cloudflare **Cache API**
（`caches.default`）中缓存 `TEMPLATE_CACHE_TTL_SECONDS`（默认 6h）。缓存过期后的
第一次请求会重新获取，其他请求则使用缓存。获取失败不会导致致命错误，而是改用内置的完整
配置骨架，因此不稳定的来源不会导致订阅失效。

这里缓存的是基础模板文本。最终订阅响应的 HTTP 缓存策略由
`RESPONSE_CACHE_CONTROL` 独立控制，默认值为 `no-store`。

远程*规则源*本身由**客户端**获取，而非由 subflow 获取，因此不受此缓存影响。

## 覆盖来源

所有来源均通过环境变量配置（参见
[04 · 密钥与配置](04-secrets-and-config.md)）。常见的覆盖原因包括：

- **固定镜像**（例如速度更快的 CDN 或自行托管的副本）：
  设置 `SUBFLOW_CLASH_RULES_BASE`、`SUBFLOW_SINGBOX_GEOSITE_BASE` 等。
- **固定版本**，而不使用 `@release` / `@master` / `rule-set`（最新版本）。
- **使用完全自定义的基础模板**：设置 `SUBFLOW_<FORMAT>_TEMPLATE_URL`。对于 Clash，
  模板可以包含标记 `#SUBFLOW_PROXIES`、`#SUBFLOW_GROUPS`、`#SUBFLOW_PROVIDERS`、
  `#SUBFLOW_RULES`，这些标记会被生成的相应部分替换；否则使用内置配置骨架。对于
  sing-box，覆盖 JSON 中的 `outbounds` 数组会被生成的 outbounds 替换。

## 默认值

默认来源基址统一定义在
[cloudflare/functions/_lib/constants.js](../cloudflare/functions/_lib/constants.js)（`RULE_SOURCES`）中，
并且都可通过环境变量覆盖，从而将配置保留在代码之外。
