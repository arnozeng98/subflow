#!/usr/bin/env bash

# ============================================================
# subflow 共享 Shell 库
# ============================================================
# 由 install.sh、menu.sh（`sf` 命令）和 uninstall.sh 引入。它包含这些脚本
# 共用的所有内容：徽标横幅、可优雅降级的柔和配色、可爱的颜文字状态辅助函数、
# 标准配置键列表（唯一事实来源），以及环境文件、systemd 和源码树的衔接逻辑。
#
# 此处没有特定于业务的内容：每个操作员配置值都在安装时或菜单中收集，
# 并写入环境文件。没有硬编码任何 IP、令牌或域名。
# ============================================================

# ----- 路径（标准、共享）------------------------------------------------------
INSTALL_ROOT="/opt/subflow"
PACKAGE_ROOT="${INSTALL_ROOT}/subflow"   # Python 包（vps/subflow）
CLI_ROOT="${INSTALL_ROOT}/cli"           # menu.sh + lib.sh + uninstall.sh
PAGES_ROOT="${INSTALL_ROOT}/pages"       # Cloudflare Pages 资源（cloudflare/functions）
ENV_DIR="/etc/subflow"
ENV_FILE="${ENV_DIR}/subflow.env"
SUBFLOW_SERVICE="subflow"
SYSTEMD_UNIT="/etc/systemd/system/subflow.service"
SUBFLOW_OPENRC_SERVICE="/etc/init.d/subflow"
SUBFLOW_OPENRC_LOG="/var/log/subflow.log"
SF_LINK="/usr/local/bin/sf"
SUBFLOW_CLOUDFLARED_SERVICE="subflow-cloudflared"
SUBFLOW_CLOUDFLARED_TOKEN_FILE="${ENV_DIR}/cloudflared.token"
SUBFLOW_CLOUDFLARED_SYSTEMD_UNIT="/etc/systemd/system/${SUBFLOW_CLOUDFLARED_SERVICE}.service"
SUBFLOW_CLOUDFLARED_OPENRC_SERVICE="/etc/init.d/${SUBFLOW_CLOUDFLARED_SERVICE}"

# 内置 sing-box 管理器（来自 vps/singbox 的内置副本）。subflow 会直接分发并安装它，
# 因此服务器不再依赖任何外部安装器。
SB_MANAGER_ROOT="${INSTALL_ROOT}/singbox"
SB_MANAGER_SCRIPT="/root/sb.sh"
SB_SHORTCUT="/usr/local/bin/s"

# 远程源码（可针对复刻仓库或分支覆盖）。
REPO_OWNER="${SUBFLOW_REPO_OWNER:-arnozeng98}"
REPO_NAME="${SUBFLOW_REPO_NAME:-subflow}"
REPO_REF="${SUBFLOW_REPO_REF:-main}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_REF}"

AUTHOR="Arno"

TMP_DIR=""

# ----- 共享终端主题 -----------------------------------------------------------
_DEPLOY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_DEPLOY_LIB_DIR}/ui.sh" ]]; then
  _UI_FILE="${_DEPLOY_LIB_DIR}/ui.sh"
else
  _UI_FILE="${_DEPLOY_LIB_DIR}/../shared/ui.sh"
fi
if [[ ! -f "${_UI_FILE}" ]]; then
  printf '未找到共享终端主题：%s\n' "${_UI_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=../shared/ui.sh
source "${_UI_FILE}"

# ----- 配置元数据（唯一事实来源）----------------------------------------------
# 在菜单和安装提示中的显示顺序。
CFG_ORDER=(
  SUBFLOW_PUBLIC_IP
  SUBFLOW_API_TOKEN
  SUBFLOW_LISTEN_HOST
  SUBFLOW_LISTEN_PORT
  SUBFLOW_CONFIG_PATH
  SUBFLOW_USER_DB_PATH
  SUBFLOW_META_PATH
  SUBFLOW_SUBSCRIPTION_INDEX_PATH
  SUBFLOW_WS_DOMAIN
  SUBFLOW_VMESS_WS_DOMAIN
  SUBFLOW_INCLUDE_DISABLED_USERS
)

declare -A CFG_DEFAULT=(
  [SUBFLOW_PUBLIC_IP]=""
  [SUBFLOW_API_TOKEN]=""
  [SUBFLOW_LISTEN_HOST]="127.0.0.1"
  [SUBFLOW_LISTEN_PORT]="28080"
  [SUBFLOW_CONFIG_PATH]="/etc/sing-box/config.json"
  [SUBFLOW_USER_DB_PATH]="/etc/sing-box-manager/user-manager.json"
  [SUBFLOW_META_PATH]="/etc/sing-box-manager/meta.json"
  [SUBFLOW_SUBSCRIPTION_INDEX_PATH]="/etc/sing-box-manager/subscriptions.json"
  [SUBFLOW_WS_DOMAIN]=""
  [SUBFLOW_VMESS_WS_DOMAIN]=""
  [SUBFLOW_INCLUDE_DISABLED_USERS]="false"
)

declare -A CFG_DESC=(
  [SUBFLOW_PUBLIC_IP]="公网 IP/域名 (必填, 作为每个节点的服务器地址)"
  [SUBFLOW_API_TOKEN]="Bearer 令牌 (Cloudflare 的 VPS_API_BEARER_TOKEN 须一致)"
  [SUBFLOW_LISTEN_HOST]="监听地址 (Cloudflare 作公开网关时建议仅本机)"
  [SUBFLOW_LISTEN_PORT]="监听端口"
  [SUBFLOW_CONFIG_PATH]="sing-box config.json 路径 (由内置管理器生成)"
  [SUBFLOW_USER_DB_PATH]="用户库 user-manager.json 路径 (由内置管理器生成)"
  [SUBFLOW_META_PATH]="元数据 meta.json 路径 (由内置管理器生成)"
  [SUBFLOW_SUBSCRIPTION_INDEX_PATH]="安全订阅索引 subscriptions.json 路径 (新管理器生成)"
  [SUBFLOW_WS_DOMAIN]="VLESS-WS 的 CDN 域名 (可选, 留空用 IP)"
  [SUBFLOW_VMESS_WS_DOMAIN]="VMess-WS 的 CDN 域名 (可选, 留空用 IP)"
  [SUBFLOW_INCLUDE_DISABLED_USERS]="是否也服务被禁用的用户 (true/false)"
)

declare -A CFG_REQUIRED=(
  [SUBFLOW_PUBLIC_IP]="yes"
)

declare -A CFG_SECRET=(
  [SUBFLOW_API_TOKEN]="yes"
)

# 安装器和菜单使用的实时值，以默认值初始化。
declare -A CFG_VALUE
seed_defaults() {
  local key
  for key in "${CFG_ORDER[@]}"; do
    CFG_VALUE[$key]="${CFG_DEFAULT[$key]}"
  done
}

init_config_meta() {
  seed_defaults
}

# ----- 通用预检 ----------------------------------------------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行。"
    exit 1
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt-get'
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    printf 'yum'
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    printf 'apk'
    return 0
  fi
  if command -v zypper >/dev/null 2>&1; then
    printf 'zypper'
    return 0
  fi
  return 1
}

detect_init_system() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    printf 'systemd'
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    printf 'openrc'
  else
    printf 'unknown'
  fi
}

INIT_SYSTEM="$(detect_init_system)"

install_packages() {
  local pkg_mgr="$1"
  shift
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0

  case "${pkg_mgr}" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install "${pkgs[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_command_with_install() {
  local cmd="$1"
  shift
  local pkgs=("$@")

  command -v "${cmd}" >/dev/null 2>&1 && return 0

  local pkg_mgr
  if ! pkg_mgr="$(detect_package_manager)"; then
    return 1
  fi

  warn "检测到缺少 ${cmd}，尝试自动安装…"
  if ! install_packages "${pkg_mgr}" "${pkgs[@]}"; then
    return 1
  fi

  command -v "${cmd}" >/dev/null 2>&1
}

require_python3() {
  if ensure_command_with_install python3 python3; then
    return 0
  fi
  err "未找到 python3，且自动安装失败。请手动安装后重试。"
  exit 1
}

require_downloader() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0

  local pkg_mgr
  if ! pkg_mgr="$(detect_package_manager)"; then
    err "未找到 curl 或 wget，且无法识别包管理器自动安装。"
    exit 1
  fi

  warn "未找到 curl/wget，尝试自动安装…"
  install_packages "${pkg_mgr}" curl wget || true

  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  err "未找到 curl 或 wget，且自动安装失败。"
  exit 1
}

require_tar() {
  if ensure_command_with_install tar tar; then
    return 0
  fi
  err "未找到 tar，且自动安装失败。"
  exit 1
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
    return 0
  fi
  date +%s%N | sha256sum | awk '{print $1}' | cut -c1-32
}

is_installed() {
  [[ -d "${PACKAGE_ROOT}" ]] && \
    [[ -f "${SYSTEMD_UNIT}" || -f "${SUBFLOW_OPENRC_SERVICE}" ]]
}

# ----- 环境文件读写 -----------------------------------------------------------
# 将现有环境值加载到 CFG_VALUE（保留已生成的令牌等）。
load_env() {
  [[ -f "${ENV_FILE}" ]] || return 0
  local key val line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key//[[:space:]]/}"
    if [[ -n "${CFG_DEFAULT[$key]+x}" ]]; then
      CFG_VALUE[$key]="${val}"
    fi
  done < "${ENV_FILE}"
}

save_env() {
  mkdir -p "${ENV_DIR}"
  # 确保令牌始终存在。
  if [[ -z "${CFG_VALUE[SUBFLOW_API_TOKEN]}" ]]; then
    CFG_VALUE[SUBFLOW_API_TOKEN]="$(generate_token)"
  fi
  cat > "${ENV_FILE}" <<EOF_ENV
# ============================================================
# subflow 运行环境配置（VPS 数据 API）
# ============================================================
# 本文件由安装器和 `sf` 菜单管理。可以手工编辑，但推荐通过 `sf` 修改。
# VPS 只暴露受令牌保护的私有数据 API；客户端配置均在 Cloudflare 组装。
#
# 令牌等敏感值只保存在 VPS 上，本文件权限必须保持为 600。
# ============================================================
SUBFLOW_API_TOKEN=${CFG_VALUE[SUBFLOW_API_TOKEN]}
SUBFLOW_LISTEN_HOST=${CFG_VALUE[SUBFLOW_LISTEN_HOST]}
SUBFLOW_LISTEN_PORT=${CFG_VALUE[SUBFLOW_LISTEN_PORT]}
SUBFLOW_CONFIG_PATH=${CFG_VALUE[SUBFLOW_CONFIG_PATH]}
SUBFLOW_USER_DB_PATH=${CFG_VALUE[SUBFLOW_USER_DB_PATH]}
SUBFLOW_META_PATH=${CFG_VALUE[SUBFLOW_META_PATH]}
SUBFLOW_SUBSCRIPTION_INDEX_PATH=${CFG_VALUE[SUBFLOW_SUBSCRIPTION_INDEX_PATH]}

# 必填：客户端实际连接的公网 IP/域名，会成为每个节点的服务器。
SUBFLOW_PUBLIC_IP=${CFG_VALUE[SUBFLOW_PUBLIC_IP]}

# 可选：WebSocket 位于 CDN 域名后方时覆盖公开主机。
SUBFLOW_WS_DOMAIN=${CFG_VALUE[SUBFLOW_WS_DOMAIN]}
SUBFLOW_VMESS_WS_DOMAIN=${CFG_VALUE[SUBFLOW_VMESS_WS_DOMAIN]}

# 是否仍向被禁用用户提供节点；默认 false。
SUBFLOW_INCLUDE_DISABLED_USERS=${CFG_VALUE[SUBFLOW_INCLUDE_DISABLED_USERS]}
EOF_ENV
  chmod 600 "${ENV_FILE}"
}

# ----- 源码树（本地或远程）----------------------------------------------------
cleanup_tmp() {
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

# 将 SOURCE_ROOT 设为包含 vps/subflow 和 vps/deploy 的目录。
prepare_source_tree() {
  local here repo_root
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd -- "${here}/../.." 2>/dev/null && pwd || true)"
  if [[ -n "${repo_root}" && -d "${repo_root}/vps/subflow" ]]; then
    info "检测到本地源码，优先使用本地文件。"
    SOURCE_ROOT="${repo_root}"
    return 0
  fi
  require_downloader
  require_tar
  TMP_DIR="$(mktemp -d /tmp/subflow-src.XXXXXX)"
  local archive_path="${TMP_DIR}/subflow.tar.gz"
  info "从 GitHub 拉取 subflow 仓库归档…"
  download_archive "${archive_path}"
  tar -xzf "${archive_path}" -C "${TMP_DIR}"
  SOURCE_ROOT="${TMP_DIR}/${REPO_NAME}-${REPO_REF}"
}

# 将 Python 包和 CLI 脚本复制到 INSTALL_ROOT。
copy_runtime() {
  [[ -n "${SOURCE_ROOT:-}" ]] || { err "源码目录未就绪。"; exit 1; }
  mkdir -p "${INSTALL_ROOT}"
  rm -rf "${PACKAGE_ROOT}"
  cp -R "${SOURCE_ROOT}/vps/subflow" "${PACKAGE_ROOT}"
  mkdir -p "${CLI_ROOT}"
  cp "${SOURCE_ROOT}/vps/deploy/lib.sh" "${CLI_ROOT}/lib.sh"
  cp "${SOURCE_ROOT}/vps/deploy/dependencies.sh" "${CLI_ROOT}/dependencies.sh"
  cp "${SOURCE_ROOT}/vps/deploy/run_subflow.py" "${CLI_ROOT}/run_subflow.py"
  cp "${SOURCE_ROOT}/vps/shared/ui.sh" "${CLI_ROOT}/ui.sh"
  cp "${SOURCE_ROOT}/vps/deploy/menu.sh" "${CLI_ROOT}/menu.sh"
  cp "${SOURCE_ROOT}/vps/deploy/cf-deploy.sh" "${CLI_ROOT}/cf-deploy.sh"
  cp "${SOURCE_ROOT}/vps/deploy/uninstall.sh" "${CLI_ROOT}/uninstall.sh"
  chmod +x "${CLI_ROOT}/menu.sh" "${CLI_ROOT}/cf-deploy.sh" \
    "${CLI_ROOT}/uninstall.sh" "${CLI_ROOT}/run_subflow.py"
  # 保留 Cloudflare Pages 资源（functions/ 和 wrangler.toml）的副本，
  # 以便菜单稍后重新部署时无需再次下载仓库。
  rm -rf "${PAGES_ROOT}"
  mkdir -p "${PAGES_ROOT}"
  cp -R "${SOURCE_ROOT}/cloudflare/functions" "${PAGES_ROOT}/functions"
  [[ -f "${SOURCE_ROOT}/cloudflare/wrangler.toml" ]] && cp "${SOURCE_ROOT}/cloudflare/wrangler.toml" "${PAGES_ROOT}/wrangler.toml"
  # 打包内置的 sing-box 管理器，使服务器可独立运行。
  if [[ -d "${SOURCE_ROOT}/vps/singbox" ]]; then
    rm -rf "${SB_MANAGER_ROOT}"
    mkdir -p "${SB_MANAGER_ROOT}"
    cp -R "${SOURCE_ROOT}/vps/singbox/." "${SB_MANAGER_ROOT}/"
    chmod +x "${SB_MANAGER_ROOT}/sb.sh" 2>/dev/null || true
  fi
}

install_cli() {
  ln -sf "${CLI_ROOT}/menu.sh" "${SF_LINK}"
  chmod +x "${SF_LINK}" 2>/dev/null || true
}

# 引导内置 sing-box 管理器：将 sb.sh 放到标准路径并提供 `s` 快捷命令。
# 此操作具有幂等性，更新时可安全地重新运行。
install_singbox_manager() {
  local src="${SB_MANAGER_ROOT}/sb.sh"
  [[ -f "${src}" ]] || src="${SOURCE_ROOT:-}/vps/singbox/sb.sh"
  [[ -f "${src}" ]] || { warn "未找到 sing-box 管理器脚本，跳过。"; return 1; }
  cp "${src}" "${SB_MANAGER_SCRIPT}"
  chmod +x "${SB_MANAGER_SCRIPT}"
  ln -sf "${SB_MANAGER_SCRIPT}" "${SB_SHORTCUT}"
  chmod +x "${SB_SHORTCUT}" 2>/dev/null || true
}

cleanup_legacy_telegram_runtime() {
  local service="sb-tg-bot" config_file="/etc/sing-box-manager/telegram.json"
  local backup_file="${config_file}.disabled" tmp

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${service}" >/dev/null 2>&1 || true
    systemctl disable "${service}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${service}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service "${service}" stop >/dev/null 2>&1 || true
    rc-update del "${service}" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${service}"
  fi

  if command -v crontab >/dev/null 2>&1; then
    tmp="$(mktemp)" || return 1
    crontab -l 2>/dev/null | awk 'index($0, "--tg-agent-sync") == 0 { print }' > "${tmp}" || true
    if [[ -s "${tmp}" ]]; then
      crontab "${tmp}" >/dev/null 2>&1 || true
    else
      crontab -r >/dev/null 2>&1 || true
    fi
    rm -f "${tmp}"
  fi

  if [[ -f "${config_file}" && ! -e "${backup_file}" ]]; then
    mv "${config_file}" "${backup_file}"
    chmod 600 "${backup_file}" >/dev/null 2>&1 || true
  else
    rm -f "${config_file}"
  fi
  rm -f \
    /etc/sing-box-manager/tg-center-bot.py \
    /etc/sing-box-manager/tg-task-receipts.json \
    /var/lock/singbox-tg-agent.lock
  rmdir /var/lock/singbox-tg-agent.lock.d >/dev/null 2>&1 || true
}

# 已安装可用的 sing-box（构建时包含 v2ray_api）时返回真。
singbox_installed() {
  [[ -x /usr/local/bin/sing-box ]] && \
    /usr/local/bin/sing-box version 2>/dev/null | grep -q with_v2ray_api
}

write_systemd_unit() {
  cat > "${SYSTEMD_UNIT}" <<EOF_UNIT
[Unit]
Description=subflow 私有订阅 API
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

write_openrc_service() {
  cat > "${SUBFLOW_OPENRC_SERVICE}" <<EOF_OPENRC
#!/sbin/openrc-run
description="subflow 私有订阅 API"
command="/usr/bin/env"
command_args="python3 ${CLI_ROOT}/run_subflow.py"
directory="${INSTALL_ROOT}"
command_background=true
pidfile="/run/${SUBFLOW_SERVICE}.pid"
output_log="${SUBFLOW_OPENRC_LOG}"
error_log="${SUBFLOW_OPENRC_LOG}"

depend() {
  need net
  after firewall
}
EOF_OPENRC
  chmod 755 "${SUBFLOW_OPENRC_SERVICE}"
}

write_service_unit() {
  case "${INIT_SYSTEM}" in
    systemd)
      write_systemd_unit
      systemctl daemon-reload
      ;;
    openrc)
      write_openrc_service
      ;;
    *)
      err "未识别 init 系统（需要 systemd 或 OpenRC）。"
      return 1
      ;;
  esac
}

service_start() {
  case "${INIT_SYSTEM}" in
    systemd) systemctl start "${SUBFLOW_SERVICE}" ;;
    openrc)  rc-service "${SUBFLOW_SERVICE}" start ;;
    *) return 1 ;;
  esac
}

service_stop() {
  case "${INIT_SYSTEM}" in
    systemd) systemctl stop "${SUBFLOW_SERVICE}" ;;
    openrc)  rc-service "${SUBFLOW_SERVICE}" stop ;;
    *) return 1 ;;
  esac
}

service_restart() {
  case "${INIT_SYSTEM}" in
    systemd) systemctl restart "${SUBFLOW_SERVICE}" ;;
    openrc)
      if rc-service "${SUBFLOW_SERVICE}" status >/dev/null 2>&1; then
        rc-service "${SUBFLOW_SERVICE}" restart
      else
        rc-service "${SUBFLOW_SERVICE}" start
      fi
      ;;
    *) return 1 ;;
  esac
}

service_enable() {
  case "${INIT_SYSTEM}" in
    systemd) systemctl enable "${SUBFLOW_SERVICE}" >/dev/null 2>&1 ;;
    openrc)  rc-update add "${SUBFLOW_SERVICE}" default >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

service_disable() {
  case "${INIT_SYSTEM}" in
    systemd) systemctl disable "${SUBFLOW_SERVICE}" >/dev/null 2>&1 ;;
    openrc)  rc-update del "${SUBFLOW_SERVICE}" default >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

reload_and_restart() {
  service_enable || true
  service_restart
}

service_status() {
  case "${INIT_SYSTEM}" in
    systemd) systemctl status "${SUBFLOW_SERVICE}" --no-pager ;;
    openrc)  rc-service "${SUBFLOW_SERVICE}" status ;;
    *) err "未识别 init 系统。"; return 1 ;;
  esac
}

service_logs() {
  case "${INIT_SYSTEM}" in
    systemd) journalctl -u "${SUBFLOW_SERVICE}" -f -n 50 ;;
    openrc)
      touch "${SUBFLOW_OPENRC_LOG}"
      tail -n 50 -f "${SUBFLOW_OPENRC_LOG}"
      ;;
    *) err "未识别 init 系统。"; return 1 ;;
  esac
}

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

# ----- 状态和信息显示 ---------------------------------------------------------
service_state() {
  case "${INIT_SYSTEM}" in
    systemd)
      systemctl is-active --quiet "${SUBFLOW_SERVICE}" 2>/dev/null && printf 'active' || printf 'inactive'
      ;;
    openrc)
      rc-service "${SUBFLOW_SERVICE}" status >/dev/null 2>&1 && printf 'active' || printf 'inactive'
      ;;
    *) printf 'inactive' ;;
  esac
}

service_enabled() {
  case "${INIT_SYSTEM}" in
    systemd)
      systemctl is-enabled --quiet "${SUBFLOW_SERVICE}" 2>/dev/null && printf 'enabled' || printf 'disabled'
      ;;
    openrc)
      rc-update show default 2>/dev/null | awk -v service="${SUBFLOW_SERVICE}" '
        $1 == service { found=1 }
        END { print found ? "enabled" : "disabled" }
      '
      ;;
    *) printf 'disabled' ;;
  esac
}

print_status_line() {
  local state enabled scolor
  state="$(service_state)"
  enabled="$(service_enabled)"
  if [[ "${state}" == "active" ]]; then
    scolor="${C_GREEN}● 运行中"
  else
    scolor="${C_RED}● 已停止"
  fi
  printf '%b\n' "    ${C_GREY}状态:${C_RESET} ${scolor}${C_RESET}   ${C_GREY}自启:${C_RESET} ${C_LAV}${enabled}${C_RESET}"
}

# show_info <mask|full> — 打印当前配置。mask 会隐藏令牌。
show_info() {
  local mode="${1:-mask}"
  load_env
  printf '%b\n' "  ${C_CYAN}${C_BOLD}当前信息${C_RESET}"
  print_status_line
  local key val shown
  for key in "${CFG_ORDER[@]}"; do
    val="${CFG_VALUE[$key]}"
    shown="${val}"
    if [[ "${CFG_SECRET[$key]:-no}" == "yes" && "${mode}" != "full" && -n "${val}" ]]; then
      shown="${val:0:6}…${val: -4}"
    fi
    printf '%b\n' "    ${C_GREY}${key}${C_RESET} = ${C_LAV}${shown:-(空)}${C_RESET}"
  done
  printf '%b\n' "    ${C_GREY}环境文件:${C_RESET} ${ENV_FILE}   ${C_GREY}安装目录:${C_RESET} ${INSTALL_ROOT}"
  printf '%b\n' "  ${C_GREY}────────────────────────────────────────────────────${C_RESET}"
}

# ----- Cloudflare 辅助函数 ----------------------------------------------------
# 这些函数供 cf-deploy.sh 使用（通过 Wrangler 直接上传进行可选的 Cloudflare 自动部署）。
# 它们绝不会将 API 令牌持久化到磁盘。

CF_API="https://api.cloudflare.com/client/v4"

# json_get <json> <python-expression-on-`d`> — 使用 VPS 已依赖的 Python 标准库
# 解析 JSON，避免依赖 jq。
json_get() {
  local data="$1" expr="$2"
  printf '%s' "${data}" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(${expr})
except Exception:
    print('')"
}

# cf_api <token> <method> <path> [data] — 调用 Cloudflare API 并输出响应正文。
cf_api() {
  local token="$1" method="$2" path="$3" data="${4:-}"
  if [[ -n "${data}" ]]; then
    curl -fsS -X "${method}" "${CF_API}${path}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "${data}" 2>/dev/null || true
  else
    curl -fsS -X "${method}" "${CF_API}${path}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" 2>/dev/null || true
  fi
}

# 检测公网 IPv4（尽力而为，仅用作建议的默认值）。
detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "${ip}" ]] && ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  printf '%s' "${ip}"
}

