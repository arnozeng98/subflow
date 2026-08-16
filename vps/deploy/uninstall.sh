#!/usr/bin/env bash

# ============================================================
# subflow VPS 卸载器
# ============================================================
# 移除 subflow 数据 API 服务、`sf` 命令及其文件，同时保留内置的 sing-box
# 管理器（`s`）和所有用户数据。运行 `s` → 8 可卸载 sing-box 本身。
# 可直接运行，也可通过菜单运行。
# ============================================================

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
else
  # lib.sh 不在同一目录时使用的最小回退方案（保持自包含）。
  INSTALL_ROOT="/opt/subflow"
  ENV_DIR="/etc/subflow"
  SUBFLOW_SERVICE="subflow"
  SYSTEMD_UNIT="/etc/systemd/system/subflow.service"
  SUBFLOW_OPENRC_SERVICE="/etc/init.d/subflow"
  SF_LINK="/usr/local/bin/sf"
  SUBFLOW_CLOUDFLARED_SERVICE="subflow-cloudflared"
  SUBFLOW_CLOUDFLARED_TOKEN_FILE="${ENV_DIR}/cloudflared.token"
  SUBFLOW_CLOUDFLARED_SYSTEMD_UNIT="/etc/systemd/system/${SUBFLOW_CLOUDFLARED_SERVICE}.service"
  SUBFLOW_CLOUDFLARED_OPENRC_SERVICE="/etc/init.d/${SUBFLOW_CLOUDFLARED_SERVICE}"
  ok()   { printf '[subflow] %s\n' "$1"; }
  err()  { printf '[subflow] %s\n' "$1" >&2; }
  require_root() { [[ "${EUID}" -eq 0 ]] || { err "请使用 root 运行卸载脚本。"; exit 1; }; }
  remove_subflow_service() {
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop "${SUBFLOW_SERVICE}" >/dev/null 2>&1 || true
      systemctl disable "${SUBFLOW_SERVICE}" >/dev/null 2>&1 || true
      rm -f "${SYSTEMD_UNIT}"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
      rc-service "${SUBFLOW_SERVICE}" stop >/dev/null 2>&1 || true
      rc-update del "${SUBFLOW_SERVICE}" default >/dev/null 2>&1 || true
      rm -f "${SUBFLOW_OPENRC_SERVICE}"
    fi
  }
fi

require_root

remove_subflow_service

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "${SUBFLOW_CLOUDFLARED_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${SUBFLOW_CLOUDFLARED_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${SUBFLOW_CLOUDFLARED_SYSTEMD_UNIT}"
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
if command -v rc-service >/dev/null 2>&1; then
  rc-service "${SUBFLOW_CLOUDFLARED_SERVICE}" stop >/dev/null 2>&1 || true
  rc-update del "${SUBFLOW_CLOUDFLARED_SERVICE}" default >/dev/null 2>&1 || true
  rm -f "${SUBFLOW_CLOUDFLARED_OPENRC_SERVICE}"
fi
rm -f "${SUBFLOW_CLOUDFLARED_TOKEN_FILE}"

rm -f "${SF_LINK}"
rm -rf "${INSTALL_ROOT}"
rm -rf "${ENV_DIR}"

ok "subflow 数据 API 已卸载；sing-box 管理器(s)与用户数据保留。后会有期～ (｡•́仸•̀｡)"
