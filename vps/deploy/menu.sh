#!/usr/bin/env bash

# ============================================================
# subflow management menu  (invoked as `sf`)
# ============================================================
# A friendly control panel for an installed subflow service: view status and
# details, edit any setting (including ones skipped at install), start/stop/
# restart, toggle autostart, tail logs, update, or uninstall. Reached through
# the /usr/local/bin/sf symlink; resolves its real path to source lib.sh.
# ============================================================

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
init_config_meta

# ----- Service switch actions ------------------------------------------------
do_start()   { systemctl start subflow.service   && ok "服务已启动～"; }
do_stop()    { systemctl stop subflow.service     && ok "服务已停止。"; }
do_restart() { systemctl restart subflow.service  && ok "服务已重启～"; }
do_enable()  { systemctl enable subflow.service >/dev/null 2>&1 && ok "已设为开机自启。"; }
do_disable() { systemctl disable subflow.service >/dev/null 2>&1 && ok "已取消开机自启。"; }

switch_menu() {
  while true; do
    printf '%b\n' ""
    printf '%b\n' "  ${C_CYAN}${C_BOLD}服务开关${C_RESET}"
    print_status_line
    printf '%b\n' "    ${C_LAV}1${C_RESET}) 启动      ${C_LAV}2${C_RESET}) 停止      ${C_LAV}3${C_RESET}) 重启"
    printf '%b\n' "    ${C_LAV}4${C_RESET}) 开机自启  ${C_LAV}5${C_RESET}) 取消自启  ${C_LAV}0${C_RESET}) 返回"
    printf '%b' "  ${C_PINK}选择${C_RESET}: "
    local c; read -r c || c="0"
    case "${c}" in
      1) do_start ;;
      2) do_stop ;;
      3) do_restart ;;
      4) do_enable ;;
      5) do_disable ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

# ----- Edit configuration ----------------------------------------------------
edit_one() {
  local key="$1"
  local current="${CFG_VALUE[$key]}"
  printf '%b\n' ""
  printf '%b\n' "  ${C_LAV}${C_BOLD}${key}${C_RESET}  ${C_GREY}${CFG_DESC[$key]}${C_RESET}"
  local shown="${current}"
  if [[ "${CFG_SECRET[$key]:-no}" == "yes" && -n "${shown}" ]]; then
    shown="${shown:0:6}…${shown: -4}"
  fi
  printf '%b\n' "    ${C_GREY}当前值：${shown:-(空)}${C_RESET}"
  local def="${CFG_DEFAULT[$key]:-}"
  if [[ -n "${def}" ]]; then
    printf '%b\n' "    ${C_GREY}默认值：${def}${C_RESET}"
  fi
  if [[ "${key}" == "SUBFLOW_API_TOKEN" ]]; then
    printf '%b' "    ${C_CYAN}输入新值${C_RESET} ${C_GREY}[回车=保留, g=重新生成]${C_RESET}: "
  else
    printf '%b' "    ${C_CYAN}输入新值${C_RESET} ${C_GREY}[回车=保留]${C_RESET}: "
  fi
  local reply; read -r reply || reply=""
  if [[ -z "${reply}" ]]; then
    note "保持不变。"
    return 0
  fi
  if [[ "${key}" == "SUBFLOW_API_TOKEN" && "${reply}" == "g" ]]; then
    reply="$(generate_token)"
    info "已重新生成 Token。"
  fi
  CFG_VALUE[$key]="${reply}"
  ok "已更新（保存后生效）。"
}

edit_menu() {
  load_env
  while true; do
    printf '%b\n' ""
    printf '%b\n' "  ${C_CYAN}${C_BOLD}修改配置${C_RESET}  ${C_GREY}选编号修改 · s 保存并重启 · 0 放弃返回${C_RESET}"
    local i=1 key shown
    for key in "${CFG_ORDER[@]}"; do
      shown="${CFG_VALUE[$key]}"
      if [[ "${CFG_SECRET[$key]:-no}" == "yes" && -n "${shown}" ]]; then
        shown="${shown:0:6}…${shown: -4}"
      fi
      printf '%b\n' "    ${C_LAV}$(printf '%2d' "${i}")${C_RESET}) ${C_GREY}${key}${C_RESET} = ${C_LAV}${shown:-(空)}${C_RESET}"
      i=$((i + 1))
    done
    printf '%b\n' "    ${C_GREEN} s${C_RESET}) 保存并重启      ${C_LAV} 0${C_RESET}) 放弃修改返回"
    printf '%b' "  ${C_PINK}选择${C_RESET}: "
    local c; read -r c || c="0"
    case "${c}" in
      s|S)
        if [[ -z "${CFG_VALUE[SUBFLOW_PUBLIC_IP]}" ]]; then
          warn "SUBFLOW_PUBLIC_IP 仍为空，节点将不可用；仍要保存？[y/N]"
          local f; read -r f || f="n"
          [[ "${f}" =~ ^[yY] ]] || continue
        fi
        save_env
        if is_installed; then reload_and_restart; fi
        ok "配置已保存并重启服务～ (๑•̀ㅂ•́)و"
        return 0
        ;;
      0) note "已放弃本次修改。"; return 0 ;;
      ''|*[!0-9]*) warn "无效选择。" ;;
      *)
        if (( c >= 1 && c < i )); then
          edit_one "${CFG_ORDER[$((c - 1))]}"
        else
          warn "无效编号。"
        fi
        ;;
    esac
  done
}

# ----- Update / reinstall ----------------------------------------------------
do_update() {
  printf '%b\n' ""
  step "从 GitHub 拉取最新源码并更新…"
  prepare_source_tree
  copy_runtime
  install_cli
  install_singbox_manager || warn "sing-box 管理器刷新失败。"
  reload_and_restart
  cleanup_tmp
  ok "已更新到最新版本并重启～ ✧*。"
}

# ----- Uninstall -------------------------------------------------------------
do_uninstall() {
  printf '%b\n' ""
  warn "即将卸载 subflow 数据 API（sing-box 与用户数据保留；如需卸载 sing-box 请运行 s → 8）。确认？[y/N]"
  local c; read -r c || c="n"
  [[ "${c}" =~ ^[yY] ]] || { note "已取消。"; return 0; }
  if [[ -x "${SCRIPT_DIR}/uninstall.sh" ]]; then
    bash "${SCRIPT_DIR}/uninstall.sh"
  else
    systemctl stop subflow.service >/dev/null 2>&1 || true
    systemctl disable subflow.service >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_UNIT}"; systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "${SF_LINK}"; rm -rf "${INSTALL_ROOT}" "${ENV_DIR}"
    ok "subflow 已卸载。后会有期～ (｡•́︿•̀｡)"
  fi
  exit 0
}

# ----- Live logs -------------------------------------------------------------
do_logs() {
  printf '%b\n' ""
  info "实时日志（Ctrl+C 退出）…"
  journalctl -u subflow.service -f -n 50 || true
}

# ----- Cloudflare deploy -----------------------------------------------------
do_cf_deploy() {
  if [[ -x "${SCRIPT_DIR}/cf-deploy.sh" ]]; then
    bash "${SCRIPT_DIR}/cf-deploy.sh" || warn "Cloudflare 部署未完成。"
  else
    err "未找到 cf-deploy.sh。请重新运行 install.sh 或 sf → 更新。"
  fi
}

# ----- sing-box manager ------------------------------------------------------
do_singbox_manager() {
  if [[ -x "${SB_MANAGER_SCRIPT}" ]]; then
    bash "${SB_MANAGER_SCRIPT}"
  elif command -v s >/dev/null 2>&1; then
    s
  else
    err "未找到内置 sing-box 管理器。请重新运行 install.sh 或 sf → 更新。"
  fi
}

# ----- Main menu -------------------------------------------------------------
main_menu() {
  while true; do
    clear 2>/dev/null || true
    banner
    show_info mask
    printf '%b\n' "  ${C_PINK}${C_BOLD}♡ 主菜单 ♡${C_RESET}"
    printf '%b\n' "    ${C_LAV}1${C_RESET}) 查看运行状态        ${C_LAV}2${C_RESET}) 查看详细信息(含完整 Token)"
    printf '%b\n' "    ${C_LAV}3${C_RESET}) 修改配置            ${C_LAV}4${C_RESET}) 服务开关(启停/自启)"
    printf '%b\n' "    ${C_LAV}5${C_RESET}) 实时日志            ${C_LAV}6${C_RESET}) 更新到最新版本"
    printf '%b\n' "    ${C_LAV}7${C_RESET}) Cloudflare 部署/重新部署"
    printf '%b\n' "    ${C_LAV}9${C_RESET}) sing-box 管理器 (安装/协议/用户/节点)"
    printf '%b\n' "    ${C_LAV}8${C_RESET}) 卸载                ${C_LAV}0${C_RESET}) 退出"
    printf '%b' "  ${C_PINK}请选择${C_RESET}: "
    local c; read -r c || c="0"
    case "${c}" in
      1) clear 2>/dev/null || true; banner; systemctl status subflow.service --no-pager || true; pause ;;
      2) clear 2>/dev/null || true; banner; show_info full; pause ;;
      3) edit_menu; pause ;;
      4) switch_menu ;;
      5) do_logs ;;
      6) do_update; pause ;;
      7) do_cf_deploy; pause ;;
      9) do_singbox_manager ;;
      8) do_uninstall ;;
      0) printf '%b\n' "  ${C_PINK}拜拜～ ♡ (＾▽＾)／${C_RESET}"; exit 0 ;;
      *) warn "无效选择，请重试。"; sleep 1 ;;
    esac
  done
}

if ! is_installed; then
  banner
  err "尚未检测到已安装的 subflow。请先运行 install.sh 安装。"
  exit 1
fi

# Subcommands: `sf status|restart|edit|…`; bare `sf` opens the menu.
case "${1:-menu}" in
  menu|"")   main_menu ;;
  status)    banner; systemctl status subflow.service --no-pager || true ;;
  info)      banner; show_info full ;;
  edit)      edit_menu ;;
  start)     do_start ;;
  stop)      do_stop ;;
  restart)   do_restart ;;
  logs)      do_logs ;;
  update)    do_update ;;
  deploy|cf) do_cf_deploy ;;
  singbox|sb) do_singbox_manager ;;
  uninstall) do_uninstall ;;
  *)         err "未知命令：$1（可用：menu/status/info/edit/start/stop/restart/logs/update/deploy/singbox/uninstall）"; exit 1 ;;
esac
