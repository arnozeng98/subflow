# Sing-box 多用户与管理脚本

这是一个基于原版 Sing-box 逻辑的一键管理脚本，专为多用户管理场景设计，自编译版本支持 v2ray_api 流量统计。
已作为 subflow 项目的一部分进行维护与分发，二进制由 subflow 仓库的 CI 从官方 SagerNet 源码自行编译。

**项目仓库**：https://github.com/arnozeng98/subflow

## 快速开始

```bash
wget -O sb.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/vps/singbox/sb.sh && bash sb.sh
```
**非root用户：**
```bash
wget -O sb.sh https://raw.githubusercontent.com/arnozeng98/subflow/main/vps/singbox/sb.sh && sudo bash sb.sh
```

* **快捷命令**：安装完成后，在终端输入 `s` 即可唤出管理菜单。
* **避免冲突**：如果当前系统已安装官方版本的 sing-box，推荐先在菜单中执行“8. 卸载 sing-box”（保留数据），再执行“1. 安装/更新 sing-box”进行环境接管。
* **升级注意（6.0.9版本之前）**：定时任务结构有变（4 个 cron 合并为 2 个）。推荐先在菜单中执行 `8. 卸载 sing-box`（保留数据），再执行 `1. 安装/更新 sing-box`，让定时任务干净迁移。如果直接覆盖新脚本，进入 `2. 系统工具` 看到摘要里 `实时同步/日常维护：未安装` 提示后，进 `1. 安装/更新` 按提示补齐组件即可。

---

## 卸载说明

菜单中的 **`8. 卸载 sing-box`** 是保留数据的运行环境卸载：

* 会停止并移除 sing-box 服务。
* 会标记 TG Bot 为停用。
* 默认保留 `/etc/sing-box`、`/etc/sing-box-manager`、日志、脚本和快捷命令，方便后续重新安装或恢复。

如需彻底清理脚本与相关配置，再手动执行：

```bash
rm -f /root/sb.sh
rm -f /usr/local/bin/s
rm -rf /etc/sing-box-manager
rm -rf /etc/sing-box
rm -rf /var/log/sing-box
rm -f /var/lock/singbox-manager.lock /var/lock/singbox-tg-agent.lock
rm -rf /var/lock/singbox-tg-agent.lock.d
```
