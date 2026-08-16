# 第三方来源与许可证

本文记录 subflow 构建、运行和生成配置时涉及的第三方项目。项目根目录的
[LICENSE](LICENSE) 只说明 subflow 自有代码的许可证，不能替代第三方项目各自的条款。

## 当前发布阻塞项

当前 [vps/singbox](vps/singbox) 中的旧版 Shell 管理器曾以
[Tangfffyx/sing-box](https://github.com/Tangfffyx/sing-box) 为来源。审计发现两者存在大量
逐字相同代码，但该上游仓库截至 2026-08-15 没有 `LICENSE`、`COPYING` 或其他明确的
复制、修改和再分发授权。

公开可见不等于允许再分发，本仓库的 AGPL-3.0 也不能替原作者授予权利。因此：

- 旧管理器不得被视为已完成许可证合规；
- 项目发布前必须用独立实现替换该目录；
- 替换完成后需重写本仓库历史和相关 Release，停止由主仓库继续分发旧 blob；
- 已存在的外部 fork、缓存或克隆无法由本仓库远程删除。

此说明是工程风险记录，不替代法律意见。

## 编译并分发的组件

### SagerNet/sing-box

- 上游：https://github.com/SagerNet/sing-box
- 许可证：GPL-3.0-or-later
- 用途：VPS 代理核心
- 构建入口：[build-sing-box.yml](.github/workflows/build-sing-box.yml)

工作流从上游正式 tag 检出源码，沿用上游 Linux 默认构建标签，删除未随包提供
`libcronet.so` 的 `with_naive_outbound`，并追加 `with_v2ray_api`。每个 Release 必须同时
提供对应源码归档、上游许可证、`BUILD_INFO.json` 和 SHA256 校验文件。

截至 2026-08-15，既有 `v1.13.18` Release 仍是加固工作流之前产生的旧资产集合，缺少
源码归档、上游许可证和 `BUILD_INFO.json`。工作流现在会把这类“tag 已存在但必要资产
不完整”的 Release 视为待重建，并使用 `gh release upload --clobber` 修复。重建可能改变
二进制摘要；修复后必须人工复核并同步
[sing-box 批准版本清单](configs/sing-box-releases.json)，在此之前安装器会拒绝摘要不匹配
的资产。

## 运行时获取的工具

| 组件 | 固定/来源 | 许可证 | 用途 |
| --- | --- | --- | --- |
| cloudflare/cloudflared | [依赖锁](configs/dependencies.lock.json) | Apache-2.0 | Cloudflare Tunnel 客户端 |
| cloudflare/workers-sdk 中的 Wrangler | [依赖锁](configs/dependencies.lock.json) | MIT OR Apache-2.0 | Cloudflare Pages 直接上传 |
| fullstorydev/grpcurl | [依赖锁](configs/dependencies.lock.json) | MIT | 查询 sing-box V2Ray API 流量统计 |

cloudflared 按架构校验项目锁定的 SHA256。Wrangler 使用精确版本，并在执行前核对 npm
registry 返回的 integrity。grpcurl 使用精确版本，并按架构强制比对项目锁定的 SHA256；
校验失败时停止安装。

Node.js、Python、Bash、curl、jq、OpenSSL、tar、cron 等由目标 Linux 发行版的软件源
提供，不由本仓库重新分发。

## 远程规则数据

以下规则不会被编译进 subflow；生成的客户端配置在运行时引用其远程 URL：

| 项目 | 许可证 | 使用方 |
| --- | --- | --- |
| SagerNet/sing-geosite | GPL-3.0-or-later | sing-box 规则集、VPS 分流 |
| SagerNet/sing-geoip | GPL-3.0-or-later | sing-box 规则集 |
| Loyalsoldier/clash-rules | GPL-3.0 | Clash/Mihomo 规则 |
| blackmatrix7/ios_rule_script | GPL-2.0 | Surge、Quantumult X 规则 |

规则 URL 和覆盖方式见[模板与规则](docs/05-templates-and-rules.md)。

## 待移除的外部安装指引

旧 WARP 菜单仍会引导用户运行 [fscarmen/warp](https://gitlab.com/fscarmen/warp) 的远程
脚本。该项目的明确再分发许可证尚未在本次审计中得到确认；subflow 没有复制其源码，
但运行远程脚本仍构成供应链风险。按既定方案，此依赖将由 sing-box 原生 WireGuard
endpoint 替换。

## 更新规则

新增、升级或移除第三方组件时必须同步：

1. 更新 [依赖锁](configs/dependencies.lock.json) 中的版本与摘要；
2. 重新生成并提交 `vps/deploy/dependencies.sh`；
3. 核实上游许可证及 NOTICE 要求；
4. 更新本文档和相关 Release 说明；
5. 运行供应链测试、生成一致性检查和完整冒烟测试。