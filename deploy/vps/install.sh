#!/usr/bin/env bash

# ============================================================
# subflow VPS installer (interactive)
# ============================================================
# Single-command install: `wget … && bash install.sh`. The installer walks the
# operator through every setting at install time (public IP, token, paths, WS
# domains, …) instead of asking them to hand-edit a file afterwards. Anything
# skipped keeps a sensible default and can be changed later from the menu (`sf`).
#
# After install, the `sf` command opens a friendly management menu.
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# When piped straight from the web (curl | bash) the sibling lib.sh may not be
# present locally; fall back to fetching the repo source tree first.
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
else
  printf '[subflow] bootstrapping from GitHub…\n'
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
    printf '[subflow] need curl or wget\n' >&2; exit 1; }
  BOOT_TMP="$(mktemp -d /tmp/subflow-boot.XXXXXX)"
  BOOT_OWNER="${SUBFLOW_REPO_OWNER:-arnozeng98}"
  BOOT_NAME="${SUBFLOW_REPO_NAME:-subflow}"
  BOOT_REF="${SUBFLOW_REPO_REF:-main}"
  BOOT_ARCHIVE="https://codeload.github.com/${BOOT_OWNER}/${BOOT_NAME}/tar.gz/refs/heads/${BOOT_REF}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${BOOT_ARCHIVE}" -o "${BOOT_TMP}/s.tar.gz"
  else
    wget -qO "${BOOT_TMP}/s.tar.gz" "${BOOT_ARCHIVE}"
  fi
  tar -xzf "${BOOT_TMP}/s.tar.gz" -C "${BOOT_TMP}"
  # shellcheck source=lib.sh
  source "${BOOT_TMP}/${BOOT_NAME}-${BOOT_REF}/deploy/vps/lib.sh"
fi

# ----- Interactive prompts ---------------------------------------------------
# prompt_value KEY — ask for one config key, honouring defaults and skip rules.
prompt_value() {
  local key="$1"
  local def="${CFG_VALUE[$key]}"
  local required="${CFG_REQUIRED[$key]:-no}"
  local secret="${CFG_SECRET[$key]:-no}"

  printf '%b\n' ""
  printf '%b\n' "  ${C_LAV}${C_BOLD}${key}${C_RESET}"
  printf '%b\n' "    ${C_GREY}${CFG_DESC[$key]}${C_RESET}"

  local hint=""
  if [[ "${key}" == "SUBFLOW_API_TOKEN" ]]; then
    hint="${C_GREY}[回车=自动生成]${C_RESET}"
  elif [[ -n "${def}" ]]; then
    hint="${C_GREY}[回车=默认 ${def}]${C_RESET}"
  elif [[ "${required}" == "yes" ]]; then
    hint="${C_YELLOW}[必填]${C_RESET}"
  else
    hint="${C_GREY}[回车=跳过, 可稍后用 sf 修改]${C_RESET}"
  fi

  while true; do
    printf '%b' "    ${C_PINK}输入${C_RESET} ${hint}: "
    local reply; read -r reply || reply=""

    if [[ -z "${reply}" ]]; then
      if [[ "${key}" == "SUBFLOW_API_TOKEN" ]]; then
        CFG_VALUE[$key]="$(generate_token)"
        ok "已自动生成 Token。"
        return 0
      fi
      if [[ "${required}" == "yes" && -z "${def}" ]]; then
        warn "该项为必填，请输入（或稍后用 sf 补填后再启动）。"
        printf '%b' "    ${C_YELLOW}仍要跳过？[y/N]${C_RESET}: "
        local skip; read -r skip || skip="n"
        [[ "${skip}" =~ ^[yY] ]] && { note "已跳过，记得稍后 sf 修改。"; return 0; }
        continue
      fi
      note "使用默认/留空。"
      return 0
    fi
    CFG_VALUE[$key]="${reply}"
    return 0
  done
}

run_wizard() {
  printf '%b\n' ""
  step "开始配置向导（每一步都可回车采用默认/跳过）"
  local key
  for key in "${CFG_ORDER[@]}"; do
    prompt_value "${key}"
  done
}

confirm_summary() {
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}${C_BOLD}请确认配置${C_RESET}"
  local key shown
  for key in "${CFG_ORDER[@]}"; do
    shown="${CFG_VALUE[$key]}"
    if [[ "${CFG_SECRET[$key]:-no}" == "yes" && -n "${shown}" ]]; then
      shown="${shown:0:6}…${shown: -4}"
    fi
    printf '%b\n' "    ${C_GREY}${key}${C_RESET} = ${C_LAV}${shown:-(空)}${C_RESET}"
  done
  printf '%b\n' ""
  printf '%b' "  ${C_PINK}确认并安装？[Y/n]${C_RESET}: "
  local c; read -r c || c="y"
  [[ -z "${c}" || "${c}" =~ ^[yY] ]]
}

print_done() {
  local token="${CFG_VALUE[SUBFLOW_API_TOKEN]}"
  printf '%b\n' ""
  ok "安装完成啦～ ♡(◕‿◕)♡"
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}服务:${C_RESET} subflow.service    ${C_CYAN}监听:${C_RESET} ${CFG_VALUE[SUBFLOW_LISTEN_HOST]}:${CFG_VALUE[SUBFLOW_LISTEN_PORT]}"
  printf '%b\n' "  ${C_CYAN}环境文件:${C_RESET} ${ENV_FILE}"
  printf '%b\n' "  ${C_CYAN}Bearer Token:${C_RESET} ${C_YELLOW}${token}${C_RESET}"
  printf '%b\n' "  ${C_GREY}↑ 在 Cloudflare 配置同样的 VPS_API_BEARER_TOKEN${C_RESET}"
  if [[ -z "${CFG_VALUE[SUBFLOW_PUBLIC_IP]}" ]]; then
    printf '%b\n' ""
    warn "SUBFLOW_PUBLIC_IP still 为空，节点暂不可用。运行 sf → 修改配置 补填后会自动重启。"
  fi
  printf '%b\n' ""
  step "随时输入 ${C_BOLD}sf${C_RESET}${C_PINK} 呼出管理菜单 (查看状态/修改配置/开关/卸载) ♡${C_RESET}"
}

# Ask which parts to install. Sets INSTALL_MODE to "api" or "api+cf".
choose_install_mode() {
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}${C_BOLD}请选择安装内容${C_RESET}"
  printf '%b\n' "    ${C_LAV}1${C_RESET}) 仅安装 VPS 数据 API ${C_GREY}(默认; Cloudflare 之后可用 sf 部署)${C_RESET}"
  printf '%b\n' "    ${C_LAV}2${C_RESET}) VPS 数据 API ${C_BOLD}+${C_RESET} Cloudflare 自动部署 ${C_GREY}(需 Cloudflare API Token)${C_RESET}"
  printf '%b' "  ${C_PINK}选择${C_RESET} ${C_GREY}[回车=默认 1]${C_RESET}: "
  local c; read -r c || c="1"
  case "${c}" in
    2) INSTALL_MODE="api+cf" ;;
    *) INSTALL_MODE="api" ;;
  esac
}

main() {
  trap cleanup_tmp EXIT
  require_root
  require_python3
  init_config_meta

  clear 2>/dev/null || true
  banner

  choose_install_mode

  # If already installed, preload existing values so the wizard pre-fills them.
  if is_installed; then
    info "检测到已安装的 subflow，向导将以现有配置为默认值。"
    load_env
  fi

  run_wizard

  while ! confirm_summary; do
    warn "重新配置一次～"
    run_wizard
  done

  step "准备源码…"
  prepare_source_tree
  step "复制运行文件与管理菜单…"
  copy_runtime
  step "写入运行环境文件…"
  save_env
  step "安装 sf 快捷命令…"
  install_cli
  step "写入 systemd 单元…"
  write_systemd_unit
  step "重载并启动服务…"
  reload_and_restart

  print_done

  if [[ "${INSTALL_MODE:-api}" == "api+cf" ]]; then
    printf '%b\n' ""
    step "进入 Cloudflare 自动部署…"
    bash "${CLI_ROOT}/cf-deploy.sh" || warn "Cloudflare 部署未完成，可稍后运行 sf → Cloudflare 部署 重试。"
  fi
}

main "$@"
