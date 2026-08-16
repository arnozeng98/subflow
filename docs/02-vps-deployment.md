# 02 · VPS 部署

VPS 服务是私有数据 API。安装程序还会在同一台机器上设置内置于
`vps/singbox` 的 sing-box 管理器。

## 前置条件

- 一台 VPS，安装程序将在其中设置 sing-box 和至少一个用户
  （通过内置管理器的 `s` 命令进行交互式配置）。
- 已安装 `python3`（3.9+）。
- 拥有 `root` 权限。
- 已安装 `curl` 或 `wget`（安装程序使用它们获取仓库归档文件）。

## 安装

```bash
wget -O subflow-install.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/vps/deploy/install.sh
bash subflow-install.sh
```

启动后，安装程序会询问**要安装的内容**：

1. **仅安装 VPS 数据 API**（默认）：之后可以使用 `sf deploy` 部署 Cloudflare。
2. **VPS 数据 API + Cloudflare 自动部署**：VPS 安装完成后立即运行 Cloudflare 向导
  （参见 [03 · Cloudflare 部署](03-cloudflare-deployment.md)）。

安装程序采用**交互方式**：安装期间会通过引导向导逐项完成所有设置，之后无需手动编辑文件。
对于每个项目，可以：

- 输入一个值；
- 按 Enter 接受显示的默认值（Bearer 令牌会自动生成）；
- 跳过可选项目，稍后再从菜单（`sf`）中修改。

随后，安装程序会：

1. 如果本地不存在源代码，则从 GitHub 下载仓库归档文件。
2. 将服务复制到 `/opt/subflow`，并将菜单和 CLI 复制到 `/opt/subflow/cli`。
3. 根据输入内容写入 `/etc/subflow/subflow.env`（权限模式为 `600`）。
4. 将 `sf` 命令安装到 `/usr/local/bin/sf`。
5. 根据系统创建并启动 `subflow` 服务（systemd 或 OpenRC）。
6. 输出 Bearer 令牌。**请妥善保存**，Cloudflare 需要使用相同的值。

不应跳过的唯一配置值是 `SUBFLOW_PUBLIC_IP`，它是将用作每个节点服务器地址的公网
IP 或主机名。如果跳过，向导会发出警告，之后可以通过 `sf` → 修改配置补充此项。

## `sf` 菜单

安装完成后，运行：

```bash
sf
```

这会打开易用的管理菜单（顶部显示徽标、作者和仓库），可在其中查看状态和完整详情、
编辑任意设置（包括安装时跳过的设置，保存后会自动重启服务）、启动/停止/重启服务、
切换开机自启、持续查看日志、更新到最新版本或卸载。

也可以使用非交互式子命令：

```bash
sf status      # 当前 init 系统中的服务状态
sf info        # 完整配置，包含令牌
sf edit        # 编辑配置
sf start|stop|restart
sf logs        # 持续查看日志
sf update      # 获取最新版本并重启
sf deploy      # 运行 Cloudflare 自动部署向导
sf uninstall
```

> 所有变量请参见 [04 · 密钥与配置](04-secrets-and-config.md)。

## 验证

服务默认监听 `127.0.0.1:28080`。包括 `/healthz` 在内的每条路由都需要 Bearer 令牌。
在 VPS 本机进行测试：

```bash
TOKEN=$(awk -F= '/^SUBFLOW_API_TOKEN=/{print $2}' /etc/subflow/subflow.env)

# 经过身份验证的健康检查：
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:28080/healthz              # 返回“正常”

# 获取真实用户名的原始数据（需要身份验证）：
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:28080/internal/raw/alice | head -c 400
```

有效用户会返回字段白名单 JSON 安全投影，其中包含 `schema_version=1`、`inbounds`、
`meta`、`public_ip`、`ws_domains` 和 `usage`。未知或已禁用的用户会返回 `404`。

## 向 Cloudflare 公开 API

Cloudflare 必须能够访问此端点，但服务仅绑定到 `127.0.0.1`。推荐使用自动化的
**Cloudflare Tunnel**：`sf deploy` 会安装 `cloudflared`、创建命名隧道，并将
`api.<host>` 指向该隧道。

系统有意**不使用**反向代理：VPS 通常已经通过 `:443` 提供 sing-box 节点服务，
因此在该端口绑定代理会产生冲突。`cloudflared` 会**主动向外**连接 Cloudflare，
所以无需开放入站端口，节点的 `:443` 也不会被占用。参见
[03 · Cloudflare 部署](03-cloudflare-deployment.md)。

请对 Bearer 令牌保密；它是数据 API 的唯一保护措施。

## 服务管理

推荐使用菜单（`sf` → 服务开关）或跨平台子命令：

```bash
sf status
sf logs
sf restart
```

也可以直接使用当前系统的服务命令：

```bash
# systemd
systemctl status subflow.service
journalctl -u subflow.service -f
systemctl restart subflow.service

# OpenRC
rc-service subflow status
tail -f /var/log/subflow.log
rc-service subflow restart
```

## 卸载

从菜单选择 `sf` → 卸载，或直接运行：

```bash
sf uninstall
```

这会移除 subflow（服务、文件和 `sf` 命令），并停止本机专属的
`subflow-cloudflared` 服务、删除本机 Tunnel 令牌。它不会改动上游 sing-box 运行环境
和用户数据，也不会自动删除 Cloudflare 账户中的 Tunnel、Pages 项目或 DNS 记录。
