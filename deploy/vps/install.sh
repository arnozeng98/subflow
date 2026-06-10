#!/usr/bin/env bash

# ============================================================
# subflow VPS installer
# ============================================================
# This installer intentionally mirrors the upstream Tangfffyx/sing-box UX:
# operators should be able to `wget` a single shell script and run it without
# manually creating directories, copying modules or authoring a systemd unit.
#
# The installer is verbose by design. The target operator is often a VPS owner
# performing remote maintenance over SSH, so every step prints what it is doing
# and why it matters.
# ============================================================

set -Eeuo pipefail

INSTALL_ROOT="/opt/subflow"
PACKAGE_ROOT="${INSTALL_ROOT}/subflow"
ENV_DIR="/etc/subflow"
ENV_FILE="${ENV_DIR}/subflow.env"
SYSTEMD_UNIT="/etc/systemd/system/subflow.service"

# The default remote source points at the current GitHub repository. Operators
# can override owner, repo or ref when testing a fork or a feature branch.
REPO_OWNER="${SUBFLOW_REPO_OWNER:-arnozeng98}"
REPO_NAME="${SUBFLOW_REPO_NAME:-subflow}"
REPO_REF="${SUBFLOW_REPO_REF:-main}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_REF}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_ROOT="${REPO_ROOT}"

TMP_DIR=""

say() {
  printf '[subflow] %s\n' "$1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    say "请使用 root 运行安装脚本。"
    exit 1
  fi
}

require_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  say "未找到 python3，请先安装 python3 后重试。"
  exit 1
}

require_downloader() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    return 0
  fi

  say "未找到 curl 或 wget，无法从 GitHub 拉取安装文件。"
  exit 1
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
    return 0
  fi

  date +%s%N | sha256sum | awk '{print $1}' | cut -c1-32
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

download_archive() {
  local archive_path="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${ARCHIVE_URL}" -o "${archive_path}"
    return 0
  fi

  wget -qO "${archive_path}" "${ARCHIVE_URL}"
}

prepare_remote_source_tree() {
  TMP_DIR="$(mktemp -d /tmp/subflow-install.XXXXXX)"
  local archive_path="${TMP_DIR}/subflow.tar.gz"
  say "从 GitHub 拉取 subflow 仓库归档..."
  download_archive "${archive_path}"
  tar -xzf "${archive_path}" -C "${TMP_DIR}"
  SOURCE_ROOT="${TMP_DIR}/${REPO_NAME}-${REPO_REF}"
}

prepare_source_tree() {
  if [[ -d "${SOURCE_ROOT}/src/subflow" ]]; then
    say "检测到本地源码，优先使用本地文件安装。"
    return 0
  fi

  require_downloader
  prepare_remote_source_tree
}

write_env_file() {
  mkdir -p "${ENV_DIR}"

  local token=""
  if [[ -f "${ENV_FILE}" ]]; then
    token="$(awk -F= '/^SUBFLOW_API_TOKEN=/{print $2}' "${ENV_FILE}" | tail -n1)"
  fi
  if [[ -z "${token}" ]]; then
    token="$(generate_token)"
  fi

  cat > "${ENV_FILE}" <<EOF_ENV
# ============================================================
# subflow environment configuration (VPS data API)
# ============================================================
# This file is loaded by the systemd unit created by install.sh.
#
# The VPS service only exposes data over a private, token-protected API. All
# client configuration assembly happens on Cloudflare. The defaults below point
# at the data files created by Tangfffyx/sing-box so the service can attach to an
# already-managed VPS.
# ============================================================
# Sensitive value. Do not commit a real token into Git. This value should only
# exist on the VPS itself in /etc/subflow/subflow.env, and must match the
# VPS_API_BEARER_TOKEN secret configured on Cloudflare.
SUBFLOW_API_TOKEN=${token}
SUBFLOW_LISTEN_HOST=127.0.0.1
SUBFLOW_LISTEN_PORT=28080
SUBFLOW_CONFIG_PATH=/etc/sing-box/config.json
SUBFLOW_USER_DB_PATH=/etc/sing-box-manager/user-manager.json
SUBFLOW_META_PATH=/etc/sing-box-manager/meta.json

# REQUIRED. Public IP (or host) clients connect to. This becomes the server
# address in every generated node. Leave empty only if you intend to set it
# before starting the service; nodes are unusable without it.
SUBFLOW_PUBLIC_IP=

# Optional WebSocket host overrides for VLESS-WS and VMess-WS nodes. Set these
# when those inbounds sit behind a CDN domain rather than the bare IP.
SUBFLOW_WS_DOMAIN=
SUBFLOW_VMESS_WS_DOMAIN=

# Set to true to also serve nodes for disabled users (default false).
SUBFLOW_INCLUDE_DISABLED_USERS=false
EOF_ENV

  chmod 600 "${ENV_FILE}"
}

copy_source_tree() {
  mkdir -p "${INSTALL_ROOT}"
  rm -rf "${PACKAGE_ROOT}"
  cp -R "${SOURCE_ROOT}/src/subflow" "${PACKAGE_ROOT}"
}

write_systemd_unit() {
  cat > "${SYSTEMD_UNIT}" <<EOF_UNIT
[Unit]
Description=subflow private subscription API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_ROOT}
ExecStart=/usr/bin/env python3 -m subflow
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

reload_and_restart() {
  systemctl daemon-reload
  systemctl enable subflow.service >/dev/null 2>&1 || true
  systemctl restart subflow.service
}

print_summary() {
  local token
  token="$(awk -F= '/^SUBFLOW_API_TOKEN=/{print $2}' "${ENV_FILE}" | tail -n1)"

  say "安装完成。"
  say "systemd 服务: subflow.service"
  say "环境文件: ${ENV_FILE}"
  say "安装目录: ${INSTALL_ROOT}"
  say "Bearer Token: ${token}"
  say "源码目录: ${PACKAGE_ROOT}"
  say "请编辑 ${ENV_FILE} 中的 SUBFLOW_PUBLIC_IP (必填) 与可选 SUBFLOW_WS_DOMAIN 后重启服务。"
  say "并在 Cloudflare 配置 VPS_API_BEARER_TOKEN 为上面的 Bearer Token。"
}

main() {
  trap cleanup EXIT
  require_root
  require_python3
  prepare_source_tree
  say "复制模块化 subflow 服务文件..."
  copy_source_tree
  say "写入运行环境文件..."
  write_env_file
  say "写入 systemd 单元..."
  write_systemd_unit
  say "重载并启动 subflow 服务..."
  reload_and_restart
  print_summary
}

main "$@"