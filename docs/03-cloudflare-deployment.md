# 03 · Cloudflare 部署

Cloudflare Pages 项目是公共网关，也是生成所有客户端配置的位置。

## 前置条件

- 一个 Cloudflare 账户。
- 已将本仓库推送到 GitHub（或直接连接本仓库）。
- 可通过 HTTPS 访问 VPS 数据 API（参见 [02 · VPS 部署](02-vps-deployment.md)）。
- VPS 安装程序输出的 Bearer 令牌。

## 方案 A：通过 VPS 安装程序自动部署（推荐）

如果已经安装 VPS 数据 API，只需在同一台机器上运行**一条命令**即可部署
Cloudflare Pages 网关，无需派生仓库，也无需 GitHub 令牌。此方式使用 Wrangler
**直接上传**，发送安装程序已经下载的 `cloudflare/functions/` 目录。

```bash
sf deploy        # 或者：运行 install.sh 并选择“VPS API + Cloudflare 自动部署”
```

向导会要求输入以下内容（每项均有说明和默认值）：

- **Cloudflare API 令牌**：在*我的个人资料 → API 令牌*中创建一个
  **自定义令牌**。此脚本所需的最低权限如下：
  - *账户 → Cloudflare Pages → 编辑*
  - *账户 → Cloudflare Tunnel → 编辑*（创建用于公开 API 的隧道）
  - *区域 → DNS → 编辑*
  - *区域 → 区域 → 读取*（按域名查找区域 ID 时需要）

  建议的资源范围：
  - *账户资源* → **包括** → 目标账户
  - *区域资源* → **包括** → 根域名所在区域（如果要复用该令牌，也可以选择所有区域）

  该令牌仅在运行时使用，绝不会写入磁盘。
- **账户 ID**：位于 *Workers & Pages → 账户 ID*（右侧边栏）。
- **根域名**：例如 `example.com`（必须是此账户中的一个区域）。
- **订阅主机名**：默认为 `subflow.<root>`，即客户端使用的公共 URL。
- **API 主机名**：默认为 `api.<subscription host>`；通过 Cloudflare Tunnel
  对外提供（橙色云朵 CNAME → `<tunnel-id>.cfargotunnel.com`），使 Pages 无需开放任何入站端口
  即可访问本机 API。
- **项目名称**：默认为 `subflow`。

如果倾向于在控制面板中手动设置令牌，同样适用上述权限集：一个令牌即可创建 Pages
项目、绑定域名、创建隧道并管理 DNS 记录。

随后，向导会验证令牌、确保 Pages 项目存在、设置 `VPS_API_BASE_URL` /
`VPS_API_BEARER_TOKEN` 机密、上传资源、安装 `cloudflared`、为 API 主机名创建并配置
命名隧道、将 DNS 指向该隧道、绑定订阅自定义域名，最后输出订阅 URL。

如果 VPS 尚未配置 `SUBFLOW_API_TOKEN`，向导会生成 Token、写入
`/etc/subflow/subflow.env` 并重启数据 API，然后再把同一个值设置为 Pages 机密，避免
两端令牌不一致。

VPS 需要 Node.js 18+、`npm` 和 `npx`。如果缺失或版本过低，向导只会尝试通过当前
发行版的系统包管理器安装 `nodejs` 与 `npm`，不会下载并执行远程 shell 安装器；
系统软件源仍无法提供合格版本时会停止并要求人工处理。

自动部署固定使用 Wrangler `4.48.0`，执行前会把 npm 返回的 integrity 与项目内锁定值
逐字比较。`cloudflared` 固定为依赖锁中的版本，并按 CPU 架构校验 SHA256 后安装。

Tunnel 由项目专属的 `subflow-cloudflared` systemd/OpenRC 服务运行。运行令牌保存在
`/etc/subflow/cloudflared.token`（mode `600`），服务通过 `--token-file` 读取，令牌不会
出现在进程命令行。项目不会卸载或重启机器上其他 cloudflared 服务。

DNS 更新采用冲突保护：同名记录不存在时创建；只有类型为 CNAME 且目标已经与预期完全
一致时才会复用并更新代理状态。如果存在 A/AAAA、不同目标的 CNAME 或多条同名记录，
部署会停止并要求先在控制面板处理，不会静默覆盖现有业务记录。

> 为什么使用隧道而不是反向代理？数据 API 只绑定到 `127.0.0.1`，而 VPS 通常已经在
> `:443` 上提供 sing-box 节点。`cloudflared` 会**向外**连接 Cloudflare，因此不会开放
> 入站端口，也不会影响节点的 `:443`。

## 方案 B：控制面板

1. **创建项目。** Cloudflare 控制面板 → *Workers & Pages* → *创建* →
   *Pages* → *连接到 Git* → 选择本仓库。
2. **构建设置。** 无需构建步骤。将*框架预设*保留为*无*，*构建命令*留空，
   *构建输出目录*设为 `/`（系统会自动检测 `cloudflare/functions/` 目录）。
3. **设置变量和机密**（参见 [04 · 机密与配置](04-secrets-and-config.md)）：
   - 机密：`VPS_API_BASE_URL`
   - 机密：`VPS_API_BEARER_TOKEN`
   - （可选变量采用 [wrangler.toml](../cloudflare/wrangler.toml) 中的默认值；如有需要，
     可在控制面板中覆盖。）
4. **部署。** 触发首次部署。
5. **自定义域名。** 在*自定义域名*中添加域名，例如 `sub.example.com`。

## 方案 C：Wrangler CLI

```bash
npm install -g wrangler@4.48.0
wrangler login

# 设置机密（交互输入，不会回显）：
wrangler pages secret put VPS_API_BASE_URL
wrangler pages secret put VPS_API_BEARER_TOKEN

# 部署：
wrangler pages deploy
```

## 本地开发

```bash
cp cloudflare/deploy/.dev.vars.example .dev.vars
# 编辑 .dev.vars，填入可访问的 VPS 基础 URL 和令牌
wrangler pages dev
```

然后测试网关：

```bash
curl -s "http://localhost:8788/alice?format=clash" | head -c 400
curl -s "http://localhost:8788/alice?format=singbox" | head -c 400
curl -s "http://localhost:8788/doesnotexist" -o /dev/null -w "%{http_code}\n"  # 返回 404
```

## 验证生产环境

使用自定义域名部署后：

```bash
curl -s "https://sub.example.com/alice?format=clash" | head
curl -s "https://sub.example.com/alice?format=singbox" | python3 -m json.tool >/dev/null && echo "valid JSON"
```

- 有效用户会返回所请求格式的完整配置。
- 未知用户会返回 Cloudflare 原生的 `404`。

完整链接格式和各客户端的导入方式请参见 [06 · 使用说明](06-usage.md)。
