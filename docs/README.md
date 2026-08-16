# subflow 文档

这里汇总 subflow 的架构、部署、配置、安全和使用说明。

| 编号 | 文档 | 内容 |
| --- | --- | --- |
| 01 | [架构](01-architecture.md) | VPS 数据 API 与 Cloudflare 网关的职责划分。 |
| 02 | [VPS 部署](02-vps-deployment.md) | 安装和验证私有数据 API。 |
| 03 | [Cloudflare 部署](03-cloudflare-deployment.md) | 创建 Pages 项目、Tunnel 和公开订阅入口。 |
| 04 | [密钥与配置](04-secrets-and-config.md) | 环境变量、默认值与密钥设置。 |
| 05 | [模板与规则](05-templates-and-rules.md) | 官方规则源、模板覆盖与缓存。 |
| 06 | [使用说明](06-usage.md) | 订阅 URL、输出格式与客户端导入。 |
| 07 | [安全与数据契约](07-security-and-data-contract.md) | 跨层字段白名单、禁止字段和修改规则。 |
| 08 | [管理器独立重写规格](08-clean-room-manager-spec.md) | 新 `s` 管理器的隔离要求、行为和验收门禁。 |

首次使用请按编号顺序阅读；快速了解项目可先看[项目说明](../README.md)。
