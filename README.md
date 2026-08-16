# subflow

subflow 将 VPS 转变为按用户提供的订阅服务，并由 Cloudflare Pages 作为前端入口。
它自带 sing-box 多用户管理器（内置于 [vps/singbox](vps/singbox)），
因此无需单独安装。

系统由两个职责明确分离的部分组成：

1. **VPS 数据 API** (`vps/subflow`)：一个受令牌保护的轻量服务，以原始 JSON
  形式公开单个用户的 sing-box 节点数据，**不进行**任何渲染。
2. **Cloudflare Pages 网关** (`functions/`)：验证用户名、获取原始数据，并使用
  从官方持续更新的数据源获取的模板和规则，**生成完整的客户端配置**（Clash、
  sing-box、Surge、Quantumult X、Shadowrocket 或通用 URI 列表）。

```
客户端 ──> Cloudflare Pages (/<user>?format=…) ──> VPS 数据 API (/internal/raw/<user>)
                  │                                         │
                  │  根据官方规则源构建完整配置              │  读取 sing-box
                  │                                         ▼
                  ▼                                  /etc/sing-box/config.json
                订阅                                 /etc/sing-box-manager/*.json
```

不同用户名会获得不同节点，配置会自动适配发起请求的客户端。

## 文档

完整指南位于 [docs/](docs/)：

- [01 · 架构](docs/01-architecture.md)：组件如何协作以及数据如何流动。
- [02 · VPS 部署](docs/02-vps-deployment.md)：安装数据 API。
- [03 · Cloudflare 部署](docs/03-cloudflare-deployment.md)：部署网关。
- [04 · 密钥与配置](docs/04-secrets-and-config.md)：所有变量和密钥。
- [05 · 模板与规则](docs/05-templates-and-rules.md)：官方数据源、缓存和覆盖配置。
- [06 · 使用方法](docs/06-usage.md)：订阅链接和客户端导入。
- [07 · 安全与数据契约](docs/07-security-and-data-contract.md)：跨层字段白名单和已知风险。

安全边界见 [SECURITY.md](SECURITY.md)，第三方来源和许可证见
[THIRD_PARTY.md](THIRD_PARTY.md)。

## 快速开始

```bash
# 1) 在 VPS 上（安装 sing-box 和数据 API）：
wget -O subflow-install.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/vps/deploy/install.sh && bash subflow-install.sh
# 安装程序采用交互方式：它会提示输入每项设置（公网 IP、令牌、路径、WS 域名）。
# 跳过的项目稍后可以在菜单中修改。
# 开始时选择“仅安装 VPS API”或“VPS API + Cloudflare 自动部署”。
# 此后可随时运行 `sf` 打开管理菜单。

# 2) Cloudflare 网关：可以让安装程序自动部署
#    （一条命令，使用 Wrangler 直接上传，无需派生仓库或 GitHub 令牌），也可以稍后部署：
sf deploy
#    它还会安装 cloudflared 并创建 Cloudflare Tunnel，使本地 API 无需开放任何入站端口
#    即可访问（sing-box 使用的 VPS :443 保持可用）。API 令牌需要 4 项权限：
#    账户 → Cloudflare Pages → 编辑、账户 → Cloudflare Tunnel → 编辑、
#    区域 → DNS → 编辑、区域 → 区域 → 读取。
#    文档也说明了通过控制面板或 CLI 手动设置的方法（参见 docs/03 和 docs/04）。
```

## 仓库结构

- [cloudflare/functions/[user].js](cloudflare/functions/[user].js)：Pages 入口点（仅负责编排）。
- [cloudflare/functions/_lib/](cloudflare/functions/_lib)：网关模块，包括配置、协议检测、
  链接构建、格式协商，以及 [cloudflare/functions/_lib/templates/](cloudflare/functions/_lib/templates)
  下各平台的配置生成器。
- [vps/subflow/](vps/subflow)：VPS 数据 API（仅提供数据，不进行渲染）。
- [vps/singbox/](vps/singbox)：内置的 sing-box 多用户管理器（`s` 命令）。
- [vps/deploy/](vps/deploy)：交互式安装程序、`sf` 管理菜单
  （[menu.sh](vps/deploy/menu.sh)）、共享库（[lib.sh](vps/deploy/lib.sh)）、
  Cloudflare 自动部署（[cf-deploy.sh](vps/deploy/cf-deploy.sh)）、
  卸载程序和 env 示例。
- [cloudflare/deploy/](cloudflare/deploy)：本地开发环境变量示例。
- [configs/](configs)：共享默认值（唯一 YAML 数据源）。
- [docs/](docs)：部署和配置指南。
- [scripts/smoke-test.mjs](scripts/smoke-test.mjs)：本地生成器冒烟测试（需要 Node 18+）。

## 设计说明

- **无硬编码配置。** 每个运维配置值都是环境变量；网关在
  [cloudflare/functions/_lib/config.js](cloudflare/functions/_lib/config.js) 中统一读取，
  VPS 则在 [vps/subflow/config.py](vps/subflow/config.py) 中读取。
- **规则始终保持最新。** 生成的配置通过客户端原生的 rule-provider、rule_set 或
  RULE-SET 机制引用官方规则源（Loyalsoldier、SagerNet、blackmatrix7），因此无需重新托管
  即可更新规则。
- **租户隔离。** VPS 只返回请求用户自己的凭据，绝不返回其他用户的密钥；返回内容采用
  字段白名单安全投影，并包含 `schema_version=1`。
- **默认不缓存订阅。** 订阅响应默认使用 `Cache-Control: no-store`，避免中间缓存保存用户配置。
