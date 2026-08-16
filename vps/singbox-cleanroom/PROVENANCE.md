# 隔离实现来源声明

## 当前状态

本目录是新 `s` 管理器的**候选实现**，当前提供平台检测、锁与可恢复事务、状态、诊断、
配置检查、订阅索引重建、用户 CRUD、VLESS Reality、Shadowsocks 2022、AnyTLS、Trojan
与 TUIC 协议 CRUD、Cloudflare DNS-01 ACME、批准版本的 sing-box 安装/更新、
systemd/OpenRC 服务管理和兼容定时入口。它尚未实现 WS Tunnel 映射、VMess/VLESS-WS、
WARP、落地、用量同步和卸载，也尚未替换 `vps/singbox`，因此不应作为完整生产管理器发布。

## 初始实现约束

初始模块由独立子代理在 2026-08-15 生成。调用时明确禁止其读取、列出、搜索、引用或
修改：

- `vps/singbox/**`
- `Tangfffyx/sing-box`

允许的输入被限制为：

- `docs/07-security-and-data-contract.md`
- `docs/08-clean-room-manager-spec.md`
- `configs/defaults.yaml`
- `configs/dependencies.lock.json`
- `configs/sing-box-releases.json`
- `vps/shared/ui.sh`
- 根 `.gitattributes`
- 专属于新实现的黑盒测试约定
- sing-box 官方公开文档

子代理生成了 `build.sh`、模块化 Bash 源码、确定性 `sb.sh` 和黑盒测试，但没有正常返回
完整的工具访问日志。因此这里只能记录调用约束，不能独立证明它实际未访问任何其他内容。

## 后续审查

主会话随后只依据新目录、07/08 规格和黑盒测试，修复了：

- 重复测试文件的机械拼接错误；
- 测试解释器路径与 Windows/Git Bash 环境差异；
- pending 事务被错误清理；
- 事务目录递归删除边界；
- 非 Shadowsocks 顶层密码与非 Reality meta 的字段白名单；
- 全用户索引与单用户租户隔离的测试边界。
- `set -e` 在条件调用上下文失效时的显式错误传播；
- 锁 FD 关闭时意外永久重定向标准错误；
- 用户库与订阅索引的双文件回滚、备份预检和原子恢复；
- 多个 pending 事务、损坏清单和事务目录符号链接边界；
- 批准版本清单嵌入、SHA256/版本/构建标签门禁；
- sing-box 二进制、版本戳和 systemd/OpenRC 服务的安装回滚与崩溃恢复。
- `config.json`、`meta.json`、`subscriptions.json` 与服务定义的协议事务和崩溃恢复；
- Reality 私钥白名单隔离、自动密钥生成和更新时凭据保持；
- Shadowsocks 2022 官方 key length、多用户密码隔离和确认式删除。
- 用户新增、启用、停用和删除与 Reality/SS2022 入站凭据、订阅索引和服务状态的
   v2 原子事务；
- 用户事务 v1 恢复兼容、v2 三文件崩溃恢复和服务失败回滚。
- Cloudflare ACME Token 的文件导入、原子 secret store、状态脱敏和 pending 事务阻断；
- AnyTLS、Trojan、TUIC 的 ACME 配置事务、逐用户凭据隔离和用户状态同步。

当前已实现的五种协议会在用户停用或删除时移除运行凭据，并在启用或新增时签发新凭据；
用户库、`config.json`、订阅索引和服务健康检查属于同一可恢复事务。后续新增
VMess/VLESS-WS 时，必须同时扩展用户凭据变更器和对应黑盒测试，否则不得把协议标记为
可用。

sing-box 1.13 的 TLS ACME 使用内联 `acme.dns01_challenge`，官方配置未提供 secret-file
引用。因此 Cloudflare Token 的权威副本存放在 `secrets/cloudflare-acme.json`，添加或
更新 TLS 协议时也会写入权限为 `600` 的运行配置。订阅索引和 VPS API 只允许投影
`tls.server_name`，测试会反向断言 `acme`、`api_token` 和 `zone_token` 不得离开 VPS。
TLS 协议引用 Cloudflare ACME 时，导入新 Token 会通过专用的 secret/config/service
可恢复事务更新全部 Cloudflare challenge，并保持非 Cloudflare provider 不变；候选配置
或服务健康检查失败时恢复旧 Token 和配置。使用中仍拒绝清除 secret，避免运行配置失去
权威副本。

安装器使用 [批准版本清单](../../configs/sing-box-releases.json) 作为信任根。清单中的
`v1.13.18` 摘要取自 2026-08-15 GitHub Release API 暴露的资产 digest；运行时仍会再次
校验 SHA256、精确版本和 `with_v2ray_api`、`with_wireguard`、`with_acme`。Release 被
修复或重建后，必须人工复核新资产并更新清单，旧摘要会按失败关闭原则拒绝新文件。

但主会话在更早的审计阶段已经阅读过旧管理器，因此主会话的这些修改不能被描述为严格
法律意义上的 clean-room 独立实现。

## 发布门禁

在替换生产目录前，必须至少满足其一：

1. 由从未接触旧实现的人员或隔离代理，根据 07/08 规格重新实现或逐项重放当前候选改动，
   并提供可审计的输入/访问记录；
2. 取得旧代码权利人的明确再分发授权；
3. 获得合格法律意见，确认当前流程与许可证处理满足发布要求。

在此之前，`vps/singbox-cleanroom` 只能用于规格验证和后续隔离开发，不能据此删除
[THIRD_PARTY.md](../../THIRD_PARTY.md) 中的发布阻塞说明。