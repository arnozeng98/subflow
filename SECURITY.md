# 安全说明

## 安全边界

subflow 将系统划分为三个安全域：

1. sing-box 管理器拥有 `/etc/sing-box` 与 `/etc/sing-box-manager` 中的完整配置和密钥。
2. VPS 数据 API 只向 Cloudflare 返回单个业务用户建立连接所需的白名单字段。
3. Cloudflare 网关把安全投影渲染为客户端订阅，不应接触服务端私钥。

Cloudflare 到 VPS 的每个 HTTP 路由都必须携带与 `SUBFLOW_API_TOKEN` 完全一致的
Bearer Token。VPS API 默认只监听 `127.0.0.1`，应通过项目管理的 Cloudflare
Tunnel 回源，不应直接开放公网端口。

## 已知风险

当前公开订阅 URL 仍以用户名作为唯一定位信息，例如 `/<用户名>`。项目尚未实现
每用户随机订阅令牌，因此猜到有效用户名的人可能取得该用户的客户端节点凭据。
在令牌机制完成前：

- 不要使用 `alice`、手机号或邮箱前缀等可猜用户名；
- 不要把订阅 URL 发到公开频道、日志或截图中；
- 保持动态订阅响应的默认 `Cache-Control: no-store`；
- 不要覆盖 `RESPONSE_CACHE_CONTROL` 为 `public` 或包含 `s-maxage` 的策略；
- 凭据疑似泄露时，应立即轮换对应节点的 UUID、密码和订阅用户名。

`no-store` 只能阻止正常工作的浏览器和共享代理保存响应，不能替代每用户鉴权。

## 绝不允许跨层传输的字段

VPS 安全投影不得包含以下服务端数据：

- Reality `private_key` 与握手内部配置；
- TLS 私钥正文、`key_path`、证书正文与 `certificate_path`；
- ACME API Token、Zone Token、账户密钥及 DNS-01 配置；
- sing-box 内部监听地址；
- 其他业务用户的 UUID、密码、状态或用量。

允许传输的客户端字段见 [数据契约](docs/07-security-and-data-contract.md)。自动化测试会用
诱饵密钥验证这些字段没有出现在函数返回值或 HTTP 响应中。

## 密钥处理

- `/etc/subflow/subflow.env`、sing-box 配置和管理器状态文件必须保持 mode `600`；
- 包含密钥的目录必须保持 mode `700`；
- Cloudflare API Token 只在交互过程中读取，不应写入仓库或普通日志；
- 菜单显示 Token 时默认脱敏，只有用户明确选择查看完整值时才输出；
- 不要在错误响应中返回上游响应正文、环境变量或本地文件内容。

## 报告安全问题

请优先使用 GitHub 仓库提供的私密漏洞报告功能。报告中可以包含复现步骤、受影响版本
和脱敏后的日志，但不要提交仍然有效的 Token、节点密码或私钥。若仓库未启用私密报告，
请先联系维护者建立私密沟通渠道，不要在公开 Issue 中粘贴凭据。