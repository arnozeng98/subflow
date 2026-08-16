# 04 · 机密与配置

所有可由运维人员调整的值均使用环境变量，没有硬编码任何业务专用值。本页列出所有环境变量，
并说明如何设置敏感变量。

## Cloudflare Pages（网关）

集中读取位置：[cloudflare/functions/_lib/config.js](../cloudflare/functions/_lib/config.js)。
非敏感默认值位于 [wrangler.toml](../cloudflare/wrangler.toml)。

| 变量 | 必需 | 类型 | 默认值 | 用途 |
| --- | --- | --- | --- | --- |
| `VPS_API_BASE_URL` | 是 | **机密** | — | VPS 数据 API 的基础 URL。 |
| `VPS_API_BEARER_TOKEN` | 是 | **机密** | — | 必须与 VPS 的 `SUBFLOW_API_TOKEN` 相同。 |
| `VPS_RAW_PATH_TEMPLATE` | 否 | 变量 | `/internal/raw/{user}` | 原始数据端点的路径模板。 |
| `REQUEST_TIMEOUT_MS` | 否 | 变量 | `8000` | 上游请求超时时间。 |
| `TEMPLATE_CACHE_TTL_SECONDS` | 否 | 变量 | `21600` | 已获取模板的 Cache API TTL。 |
| `RESPONSE_CACHE_CONTROL` | 否 | 变量 | `no-store` | 订阅响应的 `Cache-Control`；响应中包含用户凭据。 |
| `SUBFLOW_PROFILE_NAME` | 否 | 变量 | `Subflow` | 嵌入配置中的配置档案名称。 |
| `SUBFLOW_DEFAULT_FORMAT` | 否 | 变量 | `universal` | 无法识别 UA 时使用的格式。 |
| `SUBFLOW_CLASH_TEMPLATE_URL` | 否 | 变量 | — | 可选的 Clash 基础模板覆盖项。 |
| `SUBFLOW_SINGBOX_TEMPLATE_URL` | 否 | 变量 | — | 可选的 sing-box 基础模板覆盖项。 |
| `SUBFLOW_SURGE_TEMPLATE_URL` | 否 | 变量 | — | 可选的 Surge 基础模板覆盖项。 |
| `SUBFLOW_QUANTUMULTX_TEMPLATE_URL` | 否 | 变量 | — | 可选的 QX 基础模板覆盖项。 |
| `SUBFLOW_SHADOWROCKET_TEMPLATE_URL` | 否 | 变量 | — | 可选的 Shadowrocket 基础模板覆盖项。 |
| `SUBFLOW_CLASH_RULES_BASE` | 否 | 变量 | Loyalsoldier release | Clash 规则提供程序的基础地址。 |
| `SUBFLOW_SINGBOX_GEOSITE_BASE` | 否 | 变量 | SagerNet sing-geosite | sing-box geosite 规则集的基础地址。 |
| `SUBFLOW_SINGBOX_GEOIP_BASE` | 否 | 变量 | SagerNet sing-geoip | sing-box geoip 规则集的基础地址。 |
| `SUBFLOW_BLACKMATRIX7_BASE` | 否 | 变量 | blackmatrix7 master | Surge/QX RULE-SET 的基础地址。 |

本地开发模板：[cloudflare/deploy/.dev.vars.example](../cloudflare/deploy/.dev.vars.example)。

### 设置 Cloudflare 机密

**控制面板：** 项目 → *设置* → *环境变量* → 添加变量 → 开启*加密*，将其设为机密。
将 `VPS_API_BASE_URL` 和 `VPS_API_BEARER_TOKEN` 添加为机密。

**CLI：**

```bash
wrangler pages secret put VPS_API_BASE_URL
wrangler pages secret put VPS_API_BEARER_TOKEN
```

> **不要**将机密写入提交到 Git 的 `wrangler.toml` 或 `.dev.vars`。
> `.dev.vars` 仅用于本地开发，应由 Git 忽略。

## VPS 数据 API

配置由 [vps/subflow/config.py](../vps/subflow/config.py) 读取。安装程序会将配置写入
`/etc/subflow/subflow.env`。模板位于：
[vps/deploy/subflow.env.example](../vps/deploy/subflow.env.example)。

所有 VPS HTTP 路由均需要有效的 Bearer 令牌。

| 变量 | 必需 | 默认值 | 用途 |
| --- | --- | --- | --- |
| `SUBFLOW_API_TOKEN` | 是 | 自动生成 | **机密** Bearer 令牌；必须与 Cloudflare 中的令牌一致。 |
| `SUBFLOW_PUBLIC_IP` | 是 | — | 用作所有节点服务器地址的公共 IP/主机名。 |
| `SUBFLOW_LISTEN_HOST` | 否 | `127.0.0.1` | 绑定地址。 |
| `SUBFLOW_LISTEN_PORT` | 否 | `28080` | 绑定端口。 |
| `SUBFLOW_CONFIG_PATH` | 否 | `/etc/sing-box/config.json` | 上游配置文件。 |
| `SUBFLOW_USER_DB_PATH` | 否 | `/etc/sing-box-manager/user-manager.json` | 上游用户数据。 |
| `SUBFLOW_META_PATH` | 否 | `/etc/sing-box-manager/meta.json` | Reality 元数据。 |
| `SUBFLOW_SUBSCRIPTION_INDEX_PATH` | 否 | `/etc/sing-box-manager/subscriptions.json` | 带版本的安全订阅索引；文件缺失时使用旧版投影路径。 |
| `SUBFLOW_WS_DOMAIN` | 否 | — | VLESS-WS 主机名覆盖项。 |
| `SUBFLOW_VMESS_WS_DOMAIN` | 否 | — | VMess-WS 主机名覆盖项。 |
| `SUBFLOW_INCLUDE_DISABLED_USERS` | 否 | `false` | 是否同时向已禁用用户提供服务。 |

### 保护 VPS 环境变量文件

```bash
chmod 600 /etc/subflow/subflow.env      # 安装程序已经执行此操作
```

该令牌是保护数据 API 的唯一凭据。应像保护密码一样保护它；如果发生泄露，请轮换令牌
（同时更新 VPS 环境变量和 Cloudflare 机密）。

## 两端令牌必须一致

`SUBFLOW_API_TOKEN`（VPS）和 `VPS_API_BEARER_TOKEN`（Cloudflare）是两端使用的同一个
机密。如果二者不一致，网关会从 VPS 收到 `403`，并向客户端返回 `502`。
