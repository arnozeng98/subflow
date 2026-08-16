# 08 · sing-box 管理器独立重写规格

## 目的与隔离要求

本规格定义新 `s` 管理器的外部行为和数据契约。实现者只能依据本文、项目的
[安全数据契约](07-security-and-data-contract.md)、公开 sing-box 官方文档和独立编写的
测试进行实现。

独立实现期间不得读取、搜索、复制或改写以下旧代码：

- `vps/singbox/**`
- 本仓库历史中被清理前的对应路径
- `Tangfffyx/sing-box` 的源码

可以读取的项目文件：

- `configs/defaults.yaml`
- `configs/dependencies.lock.json`
- `configs/sing-box-releases.json`
- `vps/shared/ui.sh`
- `docs/07-security-and-data-contract.md`
- 本文

实现应先写入新的隔离目录，通过全部黑盒验收测试后再替换旧目录。代码评审只能按本规格
检查行为，不应逐行对照旧实现。

当前候选实现及其限制见
[隔离实现来源声明](../vps/singbox-cleanroom/PROVENANCE.md)。

## 交付形式

- 源码由职责单一的 Bash 模块组成；
- `build.sh` 确定性合并模块，生成可独立分发的单文件 `sb.sh`；
- 相同源码连续构建两次必须得到完全相同的 SHA256；
- 安装后 `/usr/local/bin/s` 执行 `/root/sb.sh`；
- 交互菜单和非交互子命令使用同一业务函数；
- 不包含 Telegram、Web UI、远程 SSH 或第三方远程安装脚本。

## 平台范围

正式支持：

- 包管理器：apt、dnf、yum、pacman、apk、zypper；
- init：systemd、OpenRC；
- CPU：Linux amd64、arm64；
- Shell：Bash；
- 必需工具：curl、jq、openssl、tar、sha256sum、flock、python3。

缺少受支持的包管理器、init、CPU 或排他锁时必须明确失败，不得静默降级。

## 文件与权限

| 路径 | 用途 | 权限 |
| --- | --- | --- |
| `/usr/local/bin/sing-box` | 锁定版本的 sing-box 二进制 | `755` |
| `/root/sb.sh` | 单文件管理器 | `700` |
| `/usr/local/bin/s` | 管理器入口 | `755` |
| `/etc/sing-box/config.json` | sing-box 运行配置 | `600` |
| `/etc/sing-box-manager/users.json` | 用户、配额和用量 | `600` |
| `/etc/sing-box-manager/meta.json` | 非敏感运行元数据引用 | `600` |
| `/etc/sing-box-manager/subscriptions.json` | VPS API 读取的订阅索引 | `600` |
| `/etc/sing-box-manager/secrets/` | ACME、WARP、落地凭据 | 目录 `700`、文件 `600` |
| `/var/lock/subflow-singbox.lock` | 全局排他锁 | `600` |

不得把 Reality 私钥、TLS 私钥、ACME Token、WARP 私钥或落地密码写入
`subscriptions.json`。

## CLI 与菜单

交互式主菜单包含：

1. 安装或更新 sing-box；
2. 协议管理；
3. 用户管理；
4. 中转与落地；
5. WARP 分流；
6. 导出和重建订阅索引；
7. 系统状态与诊断；
8. 卸载运行组件并保留数据；
0. 退出。

必须提供以下非交互命令：

```text
s status
s doctor
s install [--version <version>]
s update
s rebuild
s check
s users list
s users delete <用户名> YES
s acme status
s acme import-cloudflare <api-token-file> [zone-token-file]
s acme clear YES
s protocols list
s protocols registry
s protocols add vless-reality --tag <标签> --port <端口> --server-name <域名> [--handshake-server <域名>] [--handshake-port <端口>]
s protocols add shadowsocks-2022 --tag <标签> [--port <端口>] [--method <2022 方法>]
s protocols add anytls|trojan|tuic --tag <标签> --port <端口> --domain <域名> --email <邮箱>
s protocols update <标签> <协议参数>
s protocols delete <标签> YES
s export <username>
s uninstall
s --periodic-sync
s --daily-maintenance
```

旧参数 `--tg-agent-sync` 仅在一个迁移版本中静默返回成功，不提供任何功能。

## 统一终端主题

- 主题源为 `vps/shared/ui.sh`；
- 构建时把主题内容嵌入 `sb.sh`，运行时不依赖仓库文件；
- 使用当前 `sf` 的柔粉、薰衣草、淡青配色、SUBFLOW 横幅和颜文字状态；
- 支持 `NO_COLOR=1` 和非 TTY 输出；
- 危险操作必须输入完整 `YES`；普通确认使用 `[Y/n]` 或 `[y/N]`；
- 密钥默认不回显，摘要只显示首尾少量字符。

## 配置事务

所有写操作必须遵循同一事务：

1. 取得 `/var/lock/subflow-singbox.lock` 排他锁；
2. 读取并校验当前状态；
3. 在同一文件系统创建事务目录；
4. 生成候选 config、用户库、meta 和订阅索引；
5. 使用 `jq` 校验所有 JSON；
6. 使用锁定版本的 `sing-box check -c <候选配置>` 校验；
7. 备份旧文件并以 `rename`/`mv` 原子替换候选文件；
8. 重启或热载服务并执行健康检查；
9. 成功后删除恢复标记，失败则恢复全部旧文件和服务状态。

启动时发现未完成事务必须先恢复或明确要求人工处理，不得继续写入。

## sing-box 安装与更新

- 只从本项目批准清单安装；
- Release 资产必须有精确版本、架构和 SHA256；
- 构建来源必须是 SagerNet/sing-box 正式 tag 对应提交；
- 二进制必须包含 `with_v2ray_api`、`with_wireguard`、`with_acme`；
- 下载后先在临时位置校验 SHA256、版本和构建标签；
- 替换前备份当前二进制；
- 新二进制无法通过现有候选配置或服务健康检查时自动恢复旧版；
- 只检查更新，不自动无人值守安装；
- 至少保留最近三个已批准版本供回滚。

批准清单的仓库内唯一来源是
[`configs/sing-box-releases.json`](../configs/sing-box-releases.json)，构建 `sb.sh` 时将其
原样嵌入单文件。运行时不得从 GitHub API、`latest` 链接或与二进制同源下载的 checksum
动态扩大批准集合。Release 重建导致摘要变化时，必须先人工核对来源、构建信息和许可证
资产，再提交新摘要。

这里的 V2Ray API 只是 sing-box 的本地 gRPC 流量统计接口，不安装 V2Ray 核心。

## 用户数据

用户库必须包含 `schema_version` 和以用户名为键的 `users` 对象。用户名规则与公开 API
一致：1 至 64 个 ASCII 字母、数字、下划线或短横线。

每个用户至少包含：

```json
{
  "enabled": true,
  "disabled_reason": null,
  "quota_gb": 0,
  "used_up_bytes": 0,
  "used_down_bytes": 0,
  "manual_added_bytes": 0,
  "last_live_up_bytes": 0,
  "last_live_down_bytes": 0,
  "last_reset_period": "",
  "reset_day": 0,
  "expire_at": "0",
  "allow_all_nodes": true,
  "nodes": []
}
```

- `quota_gb=0` 表示不限量；
- `reset_day=0` 表示不重置，`1..31` 表示对应日期，`32` 表示每月最后一天；
- `expire_at="0"` 表示永久，否则使用 `YYYY-MM-DD`；
- 用量、配额、到期和重置计算统一使用 `Asia/Shanghai`；
- 过期或超额停用必须记录明确的 `disabled_reason`；
- 管理员手工停用不能被自动重置逻辑意外恢复。
- 用户新增、启用、停用和删除必须在同一事务中同步受管入站凭据；停用和删除必须移除
  旧凭据，重新启用时必须签发新凭据；
- 配额、到期日和重置日等不改变连接身份的更新不得轮换现有凭据或无故重启服务；
- 每新增一种入站协议，必须同步实现该协议的用户凭据新增与撤销，不能只更新订阅索引。

## 订阅索引

每次协议、用户、权限、状态或用量变化后，必须在同一事务中重建
`subscriptions.json`。索引根结构遵循 `schema_version=1` 和 `users` 映射。

每个用户记录包含：

- `usage`：该用户规范化后的状态与用量；
- `inbounds`：仅包含安全数据契约允许字段，且 `users` 中只有该用户；
- `meta`：仅包含 Reality 公钥。

索引不得先复制完整 sing-box 对象再删除已知秘密，必须从空对象逐字段构造。

## 首批入站协议

首批只实现：

- VLESS Reality；
- AnyTLS；
- Shadowsocks 2022；
- Trojan；
- VMess-WS；
- VLESS-WS；
- TUIC。

每个协议由独立构建器生成候选 JSON，并由统一注册表声明协议名、传输层、默认端口和导出
能力。新增协议不得修改多个散落的协议判断。

SOCKS 不作为公开订阅入站。兼容用途仅允许绑定回环或明确私网地址。

## TLS 与 WebSocket

- Reality 使用用户选择的公开握手站点和自动生成密钥对；订阅索引只记录公钥；
- AnyTLS、Trojan、TUIC 必须使用用户实际控制的域名；
- 默认通过 sing-box 官方 ACME 能力和 Cloudflare DNS-01 获取证书；
- Cloudflare Token 存在 secrets 目录，日志与菜单必须脱敏；
- sing-box 1.13 的内联 ACME 没有 secret-file 引用，因此运行配置中也会包含 Token；该文件
  必须保持 `600`，Token 不得出现在订阅索引、VPS API、日志、菜单或命令行参数中；
- TLS 协议引用 Cloudflare ACME 时，Token 轮换必须在同一事务中更新 secret store、全部
  Cloudflare challenge 和服务状态；候选配置或健康检查失败时恢复旧状态；
- TLS 协议仍在引用 Cloudflare ACME 时不得清除 secret store，必须先删除相关协议；
- 新建节点不得默认设置 `allowInsecure` 或 `skip-cert-verify`；
- 旧自签名节点只能通过显式迁移兼容模式继续使用。

VMess-WS/VLESS-WS 记录本地监听地址、端口、唯一 path 和公开域名。只有 Cloudflare
Tunnel 已存在对应 host/path → `127.0.0.1:<本地端口>` 映射时，才允许进入订阅索引；
客户端公开端口为 `443`。

## WARP

- 使用 sing-box 原生 WireGuard endpoint；
- 只导入用户已有的 WireGuard/WARP 参数，不负责注册 WARP 账户；
- 支持 address、private_key、peer address/port/public_key、allowed_ips、reserved；
- 私钥存入 secrets 目录，不进入 meta 或订阅索引；
- 不下载或执行 fscarmen/WireProxy 等第三方脚本；
- 分流规则使用 SagerNet 远程 `.srs`，下载走 direct。

## 落地与分流

- 项目不通过 SSH 登录或安装远端 VPS；
- 首批支持 VLESS Reality 与 Shadowsocks 2022 加密出站；
- 高级导入只接受明确白名单类型，并必须通过 `sing-box check`；
- 公网明文 SOCKS 默认拒绝；
- 全量中转和部分规则中转共享同一 landing 数据模型；
- 同一规则只能属于 WARP 或某个 landing，切换前必须明确确认；
- 应提供 TCP/UDP 或协议握手层面的连通性诊断，失败时不提交事务。

## 维护任务

- `--periodic-sync`：同步 V2Ray API 用量、应用配额/到期/重置规则、重建订阅索引；
- `--daily-maintenance`：日志轮转、检查上游版本、清理过期事务备份；
- systemd 使用 timer，OpenRC 使用 cron；
- 定时任务必须使用非阻塞锁，已有交互事务时跳过本轮；
- 错误写入日志，不得用全局 `>/dev/null 2>&1` 完全吞掉。

## 迁移

首次运行新管理器时：

1. 检测旧 config、用户库和 meta；
2. 只读取数据，不执行旧脚本；
3. 创建带时间戳的只读备份；
4. 转换为新 schema 并运行完整候选事务；
5. 清理旧 Telegram service/cron/app/lock，原配置先重命名为 `.disabled`；
6. 不自动改变现有协议端口、用户凭据或节点权限；
7. WARP、TLS 与落地升级由单独显式向导执行。

## 验收门禁

- 所有 Shell 文件通过 `bash -n` 与 ShellCheck；
- amd64/arm64、systemd/OpenRC、六类包管理器有矩阵测试；
- 连续两次构建的 `sb.sh` SHA256 相同；
- 模拟锁竞争、断电、损坏 JSON、摘要不匹配、服务启动失败均能安全恢复；
- 每种协议使用 stable 与 candidate sing-box 执行 `sing-box check`；
- 订阅索引测试证明不存在服务端秘密和其他用户凭据；
- `NO_COLOR=1` 输出无 ANSI 转义；
- 源码和生成物均不包含 Telegram API、Bot 菜单或远程管理入口；
- 在替换旧目录前，由未读取旧实现的人员或隔离代理签署实现来源声明。