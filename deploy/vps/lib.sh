#!/usr/bin/env bash

# ============================================================
# subflow shared shell library
# ============================================================
# Sourced by install.sh, menu.sh (the `sf` command) and uninstall.sh. It holds
# everything those scripts have in common: the logo banner, a soft colour
# palette with graceful degradation, cute kaomoji status helpers, the canonical
# list of configuration keys (single source of truth), and the env / systemd /
# source-tree plumbing.
#
# Nothing here is business-specific: every operator value is collected at
# install time or in the menu and written to the env file. No IPs, tokens or
# domains are hard-coded.
# ============================================================

# ----- Paths (canonical, shared) ---------------------------------------------
INSTALL_ROOT="/opt/subflow"
PACKAGE_ROOT="${INSTALL_ROOT}/subflow"   # python package (src/subflow)
CLI_ROOT="${INSTALL_ROOT}/cli"           # menu.sh + lib.sh + uninstall.sh
PAGES_ROOT="${INSTALL_ROOT}/pages"       # Cloudflare Pages assets (functions/)
ENV_DIR="/etc/subflow"
ENV_FILE="${ENV_DIR}/subflow.env"
SYSTEMD_UNIT="/etc/systemd/system/subflow.service"
SF_LINK="/usr/local/bin/sf"

# Remote source (overridable for forks / branches).
REPO_OWNER="${SUBFLOW_REPO_OWNER:-arnozeng98}"
REPO_NAME="${SUBFLOW_REPO_NAME:-subflow}"
REPO_REF="${SUBFLOW_REPO_REF:-main}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_REF}"

AUTHOR="Arno"

TMP_DIR=""

# ----- Colour palette --------------------------------------------------------
# Soft, coordinated pastels. Disabled automatically when stdout is not a TTY or
# the terminal cannot do colour, so logs and pipes stay clean.
setup_colors() {
  local ncolors=0
  if command -v tput >/dev/null 2>&1; then
    ncolors="$(tput colors 2>/dev/null || printf '0')"
  fi
  if [[ -t 1 && "${ncolors}" -ge 8 && "${NO_COLOR:-}" == "" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_PINK=$'\033[38;5;218m'    # soft pink
    C_LAV=$'\033[38;5;183m'     # lavender
    C_CYAN=$'\033[38;5;117m'    # baby cyan
    C_GREEN=$'\033[38;5;151m'   # mint green
    C_YELLOW=$'\033[38;5;229m'  # pale yellow
    C_RED=$'\033[38;5;210m'     # soft coral
    C_GREY=$'\033[38;5;246m'    # muted grey
  else
    C_RESET="" C_BOLD="" C_DIM="" C_PINK="" C_LAV="" C_CYAN=""
    C_GREEN="" C_YELLOW="" C_RED="" C_GREY=""
  fi
}
setup_colors

# ----- Kaomoji status helpers ------------------------------------------------
ok()   { printf '%b\n' "  ${C_GREEN}(๑˃ᴗ˂)ﻭ  $1${C_RESET}"; }
info() { printf '%b\n' "  ${C_CYAN}(｡･ω･)ﾉ  $1${C_RESET}"; }
note() { printf '%b\n' "  ${C_GREY}(・∀・)    $1${C_RESET}"; }
warn() { printf '%b\n' "  ${C_YELLOW}(・_・;)   $1${C_RESET}"; }
err()  { printf '%b\n' "  ${C_RED}(╥﹏╥)    $1${C_RESET}" >&2; }
step() { printf '%b\n' "  ${C_PINK}♡ $1${C_RESET}"; }

pause() {
  printf '%b' "  ${C_GREY}按回车继续…${C_RESET}"
  read -r _ || true
}

# ----- Logo banner -----------------------------------------------------------
banner() {
  printf '%b\n' ""
  printf '%b\n' "${C_PINK}  ███████╗██╗   ██╗██████╗ ███████╗██╗      ██████╗ ██╗    ██╗${C_RESET}"
  printf '%b\n' "${C_PINK}  ██╔════╝██║   ██║██╔══██╗██╔════╝██║     ██╔═══██╗██║    ██║${C_RESET}"
  printf '%b\n' "${C_LAV}  ███████╗██║   ██║██████╔╝█████╗  ██║     ██║   ██║██║ █╗ ██║${C_RESET}"
  printf '%b\n' "${C_LAV}  ╚════██║██║   ██║██╔══██╗██╔══╝  ██║     ██║   ██║██║███╗██║${C_RESET}"
  printf '%b\n' "${C_CYAN}  ███████║╚██████╔╝██████╔╝██║     ███████╗╚██████╔╝╚███╔███╔╝${C_RESET}"
  printf '%b\n' "${C_CYAN}  ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝ ${C_RESET}"
  printf '%b\n' ""
  printf '%b\n' "  ${C_GREY}per-user sing-box subscriptions, fronted by Cloudflare${C_RESET}"
  printf '%b\n' "  ${C_PINK}♡${C_RESET} ${C_BOLD}author${C_RESET} ${C_LAV}${AUTHOR}${C_RESET}   ${C_PINK}♡${C_RESET} ${C_BOLD}repo${C_RESET} ${C_CYAN}${REPO_URL}${C_RESET}"
  printf '%b\n' "  ${C_GREY}────────────────────────────────────────────────────${C_RESET}"
}

# ----- Configuration metadata (single source of truth) -----------------------
# Order shown in menus / install prompts.
CFG_ORDER=(
  SUBFLOW_PUBLIC_IP
  SUBFLOW_API_TOKEN
  SUBFLOW_LISTEN_HOST
  SUBFLOW_LISTEN_PORT
  SUBFLOW_CONFIG_PATH
  SUBFLOW_USER_DB_PATH
  SUBFLOW_META_PATH
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
  [SUBFLOW_WS_DOMAIN]=""
  [SUBFLOW_VMESS_WS_DOMAIN]=""
  [SUBFLOW_INCLUDE_DISABLED_USERS]="false"
)

declare -A CFG_DESC=(
  [SUBFLOW_PUBLIC_IP]="公网 IP/域名 (必填, 作为每个节点的 server 地址)"
  [SUBFLOW_API_TOKEN]="Bearer Token (Cloudflare 的 VPS_API_BEARER_TOKEN 须一致)"
  [SUBFLOW_LISTEN_HOST]="监听地址 (Cloudflare 作公开网关时建议仅本机)"
  [SUBFLOW_LISTEN_PORT]="监听端口"
  [SUBFLOW_CONFIG_PATH]="上游 sing-box config.json 路径"
  [SUBFLOW_USER_DB_PATH]="上游 user-manager.json 路径"
  [SUBFLOW_META_PATH]="上游 meta.json 路径"
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

# Live values used by install/menu. Seeded from defaults.
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

# ----- Common preflight ------------------------------------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行。"
    exit 1
  fi
}

require_python3() {
  command -v python3 >/dev/null 2>&1 && return 0
  err "未找到 python3，请先安装 python3 后重试。"
  exit 1
}

require_downloader() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  err "未找到 curl 或 wget，无法从 GitHub 拉取安装文件。"
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
  [[ -f "${SYSTEMD_UNIT}" && -d "${PACKAGE_ROOT}" ]]
}

# ----- env file read / write -------------------------------------------------
# Load existing env values into CFG_VALUE (keeps generated token, etc.).
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
  # Ensure a token always exists.
  if [[ -z "${CFG_VALUE[SUBFLOW_API_TOKEN]}" ]]; then
    CFG_VALUE[SUBFLOW_API_TOKEN]="$(generate_token)"
  fi
  cat > "${ENV_FILE}" <<EOF_ENV
# ============================================================
# subflow environment configuration (VPS data API)
# ============================================================
# Managed by the subflow installer / the \`sf\` menu. You may edit by hand, but
# the menu (run: sf) is the easiest way. The VPS exposes a private, token-
# protected data API only; all client config assembly happens on Cloudflare.
#
# Sensitive values (token) live only here on the VPS. Keep this file at mode 600.
# ============================================================
SUBFLOW_API_TOKEN=${CFG_VALUE[SUBFLOW_API_TOKEN]}
SUBFLOW_LISTEN_HOST=${CFG_VALUE[SUBFLOW_LISTEN_HOST]}
SUBFLOW_LISTEN_PORT=${CFG_VALUE[SUBFLOW_LISTEN_PORT]}
SUBFLOW_CONFIG_PATH=${CFG_VALUE[SUBFLOW_CONFIG_PATH]}
SUBFLOW_USER_DB_PATH=${CFG_VALUE[SUBFLOW_USER_DB_PATH]}
SUBFLOW_META_PATH=${CFG_VALUE[SUBFLOW_META_PATH]}

# REQUIRED. Public IP/host clients connect to; becomes every node's server.
SUBFLOW_PUBLIC_IP=${CFG_VALUE[SUBFLOW_PUBLIC_IP]}

# Optional WebSocket host overrides (set when behind a CDN domain).
SUBFLOW_WS_DOMAIN=${CFG_VALUE[SUBFLOW_WS_DOMAIN]}
SUBFLOW_VMESS_WS_DOMAIN=${CFG_VALUE[SUBFLOW_VMESS_WS_DOMAIN]}

# Set to true to also serve nodes for disabled users (default false).
SUBFLOW_INCLUDE_DISABLED_USERS=${CFG_VALUE[SUBFLOW_INCLUDE_DISABLED_USERS]}
EOF_ENV
  chmod 600 "${ENV_FILE}"
}

# ----- Source tree (local or remote) -----------------------------------------
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

# Sets SOURCE_ROOT to a directory containing src/subflow + deploy/vps.
prepare_source_tree() {
  local here repo_root
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd -- "${here}/../.." 2>/dev/null && pwd || true)"
  if [[ -n "${repo_root}" && -d "${repo_root}/src/subflow" ]]; then
    info "检测到本地源码，优先使用本地文件。"
    SOURCE_ROOT="${repo_root}"
    return 0
  fi
  require_downloader
  TMP_DIR="$(mktemp -d /tmp/subflow-src.XXXXXX)"
  local archive_path="${TMP_DIR}/subflow.tar.gz"
  info "从 GitHub 拉取 subflow 仓库归档…"
  download_archive "${archive_path}"
  tar -xzf "${archive_path}" -C "${TMP_DIR}"
  SOURCE_ROOT="${TMP_DIR}/${REPO_NAME}-${REPO_REF}"
}

# Copy python package + CLI scripts into INSTALL_ROOT.
copy_runtime() {
  [[ -n "${SOURCE_ROOT:-}" ]] || { err "源码目录未就绪。"; exit 1; }
  mkdir -p "${INSTALL_ROOT}"
  rm -rf "${PACKAGE_ROOT}"
  cp -R "${SOURCE_ROOT}/src/subflow" "${PACKAGE_ROOT}"
  mkdir -p "${CLI_ROOT}"
  cp "${SOURCE_ROOT}/deploy/vps/lib.sh" "${CLI_ROOT}/lib.sh"
  cp "${SOURCE_ROOT}/deploy/vps/menu.sh" "${CLI_ROOT}/menu.sh"
  cp "${SOURCE_ROOT}/deploy/vps/cf-deploy.sh" "${CLI_ROOT}/cf-deploy.sh"
  cp "${SOURCE_ROOT}/deploy/vps/uninstall.sh" "${CLI_ROOT}/uninstall.sh"
  chmod +x "${CLI_ROOT}/menu.sh" "${CLI_ROOT}/cf-deploy.sh" "${CLI_ROOT}/uninstall.sh"
  # Keep a copy of the Cloudflare Pages assets (functions/ + wrangler.toml) so
  # the menu can re-deploy later without re-downloading the repo.
  rm -rf "${PAGES_ROOT}"
  mkdir -p "${PAGES_ROOT}"
  cp -R "${SOURCE_ROOT}/functions" "${PAGES_ROOT}/functions"
  [[ -f "${SOURCE_ROOT}/wrangler.toml" ]] && cp "${SOURCE_ROOT}/wrangler.toml" "${PAGES_ROOT}/wrangler.toml"
}

install_cli() {
  ln -sf "${CLI_ROOT}/menu.sh" "${SF_LINK}"
  chmod +x "${SF_LINK}" 2>/dev/null || true
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

# ----- Status / info display -------------------------------------------------
service_state() {
  systemctl is-active subflow.service 2>/dev/null || printf 'inactive'
}

service_enabled() {
  systemctl is-enabled subflow.service 2>/dev/null || printf 'disabled'
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

# show_info <mask|full> — prints current configuration. mask hides the token.
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

# ----- Cloudflare helpers ----------------------------------------------------
# These are used by cf-deploy.sh (optional automated Cloudflare deployment via
# Wrangler Direct Upload). They never persist the API token to disk.

CF_API="https://api.cloudflare.com/client/v4"

# json_get <json> <python-expression-on-`d`> — parse JSON with the stdlib python
# that the VPS already requires. Avoids a jq dependency.
json_get() {
  local data="$1" expr="$2"
  printf '%s' "${data}" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(${expr})
except Exception:
    print('')"
}

# cf_api <token> <method> <path> [data] — call the Cloudflare API, echo body.
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

# detect public IPv4 (best-effort, used only as a suggested default).
detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "${ip}" ]] && ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  printf '%s' "${ip}"
}

