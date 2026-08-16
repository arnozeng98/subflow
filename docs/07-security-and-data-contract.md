# 07 · 安全与数据契约

本文定义 VPS 数据 API 与 Cloudflare 网关之间允许传输的数据。该契约是安全边界，
不是 sing-box `config.json` 的镜像。

## 请求

Cloudflare 使用以下内部接口读取单个用户的数据：

```http
GET /internal/raw/<用户名>
Authorization: Bearer <SUBFLOW_API_TOKEN>
Accept: application/json
```

用户名必须为 1 至 64 个 ASCII 字母、数字、下划线或短横线。所有路由，包括
`/healthz`，都要求 Bearer Token。未知、禁用或没有可用节点的用户统一返回 `404`。

## 顶层响应

成功响应为 JSON，对象只允许包含以下顶层字段：

| 字段 | 含义 |
| --- | --- |
| `schema_version` | 当前数据契约版本，现为 `1`。 |
| `username` | 当前业务用户名。 |
| `enabled` | 用户是否启用。 |
| `usage` | 当前用户的配额、用量、重置日和到期状态。 |
| `public_ip` | 客户端连接节点时使用的公开地址。 |
| `ws_domains` | VLESS-WS 与 VMess-WS 的公开域名覆盖。 |
| `inbounds` | 经过白名单投影的客户端连接参数。 |
| `meta` | 仅包含按 inbound tag 索引的 Reality 公钥。 |

VPS 响应始终使用 `Cache-Control: no-store`。

## 订阅索引与兼容路径

数据 API 优先读取 `/etc/sing-box-manager/subscriptions.json`，也可通过
`SUBFLOW_SUBSCRIPTION_INDEX_PATH` 覆盖。索引结构如下：

```json
{
	"schema_version": 1,
	"users": {
		"alice": {
			"usage": {},
			"inbounds": [],
			"meta": {}
		}
	}
}
```

只有索引文件完全不存在时，API 才读取旧版 `config.json`、`user-manager.json` 和
`meta.json` 现场构建安全投影。索引一旦存在，就成为唯一用户集合：用户不存在时返回
`404`；JSON 损坏、结构错误或版本不兼容时返回通用 `500`，不得静默回退到旧文件。

即使索引文件由受信任的本机管理器写入，API 仍会再次执行字段白名单和用户名过滤，
不会直接把索引记录原样返回。

## Inbound 白名单

每个 `inbounds` 元素只允许包含：

- 通用字段：`type`、`tag`、`listen_port`、`users`；
- Shadowsocks 2022：`method`、服务端 `password`；
- WebSocket：`transport.type`、`transport.path`；
- TLS：`tls.server_name`；
- Reality：`tls.reality.enabled`、`tls.reality.short_id`。

每个 `users` 元素只允许包含 `name`、`username`、`uuid`、`password`、`flow`，
并且必须属于 URL 中指定的业务用户。Shadowsocks 2022 的服务端密码与用户密码都属于
客户端建立连接所需数据，因此是有意保留的例外。

## 禁止字段

实现必须采用“从空对象选择允许字段”的方式，禁止先复制完整对象再删除已知密钥。
后者会在 sing-box 新增字段时自动泄露未知数据。

以下内容不得出现在响应中：

- `listen` 内部绑定地址；
- Reality `private_key`、`handshake`；
- TLS `key`、`key_path`、`certificate`、`certificate_path`；
- `acme`、`api_token`、`zone_token`、ACME 账户密钥；
- 路由、出站、日志和实验性服务配置；
- 非当前用户的任何凭据或使用量。

## 修改契约

新增协议或字段时必须同时完成：

1. 证明该字段是客户端建立连接所必需，而不是服务端运行信息；
2. 在 `raw_projection.py` 中显式加入白名单；
3. 在 Python 测试中加入允许字段断言和诱饵秘密反向断言；
4. 在 Cloudflare 节点模型与六种输出格式测试中覆盖该字段；
5. 更新本文档后再发布。

相关测试：

- `tests/python/test_raw_projection.py`
- `tests/python/test_http_handlers.py`
- `tests/js/cache-control.test.mjs`