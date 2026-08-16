subflow_print_menu() {
  banner
  printf '%b\n' "  ${C_BOLD}主菜单${C_RESET}"
  printf '%b\n' "  1. 安装或更新 sing-box"
  printf '%b\n' "  2. 协议管理"
  printf '%b\n' "  3. 用户管理"
  printf '%b\n' "  4. 中转与落地（后续里程碑）"
  printf '%b\n' "  5. WARP 分流（后续里程碑）"
  printf '%b\n' "  6. 导出和重建订阅索引"
  printf '%b\n' "  7. 系统状态与诊断"
  printf '%b\n' "  8. 卸载运行组件并保留数据（后续里程碑）"
  printf '%b\n' "  0. 退出"
}

subflow_menu_once() {
  subflow_print_menu
  if [[ -t 0 ]]; then
    printf '%b' "  ${C_GREY}请选择 [0-8]: ${C_RESET}"
    local choice
    if ! read -r choice; then
      return 0
    fi
    case "$choice" in
      0) return 0 ;;
      6) cmd_rebuild ;;
      7) cmd_status ; cmd_doctor ;;
      1)
        if subflow_binary_exists; then
          cmd_update
        else
          cmd_install_dispatch
        fi
        ;;
      2) subflow_protocol_list ;;
      3) subflow_users_list ;;
      4|5|8)
        warn "该功能将在后续里程碑实现"
        return 1
        ;;
      *)
        warn "未知选项"
        return 1
        ;;
    esac
  fi
  return 0
}

cmd_users_dispatch() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    list)
      subflow_users_list
      ;;
    add)
      local username quota_gb="0" reset_day="0" expire_at="0" option value
      username="${1:-}"
      shift || true
      [[ -n "$username" ]] || { err "缺少用户名"; return 1; }
      while [[ "$#" -gt 0 ]]; do
        option="$1"
        case "$option" in
          --quota)
            value="${2:-}"
            [[ -n "$value" ]] || { err "--quota 需要参数"; return 1; }
            quota_gb="$value"
            shift 2
            ;;
          --reset-day)
            value="${2:-}"
            [[ -n "$value" ]] || { err "--reset-day 需要参数"; return 1; }
            reset_day="$value"
            shift 2
            ;;
          --expire)
            value="${2:-}"
            [[ -n "$value" ]] || { err "--expire 需要参数"; return 1; }
            expire_at="$value"
            shift 2
            ;;
          *)
            err "未知参数: ${option}"
            return 1
            ;;
        esac
      done
      cmd_users_add "$username" "$quota_gb" "$reset_day" "$expire_at"
      ;;
    enable|disable|delete)
      local username="${1:-}"
      [[ -n "$username" ]] || { err "缺少用户名"; return 1; }
      case "$subcmd" in
        enable) cmd_users_enable "$username" ;;
        disable) cmd_users_disable "$username" ;;
        delete)
          [[ "$#" -eq 2 && "${2:-}" == "YES" ]] \
            || { err "用法: users delete <用户名> YES"; return 1; }
          cmd_users_delete "$username"
          ;;
      esac
      ;;
    set-quota)
      local username="${1:-}" quota_gb="${2:-}"
      [[ -n "$username" && -n "$quota_gb" ]] || { err "参数不足"; return 1; }
      cmd_users_set_quota "$username" "$quota_gb"
      ;;
    set-expire)
      local username="${1:-}" expire_at="${2:-}"
      [[ -n "$username" && -n "$expire_at" ]] || { err "参数不足"; return 1; }
      cmd_users_set_expire "$username" "$expire_at"
      ;;
    set-reset-day)
      local username="${1:-}" reset_day="${2:-}"
      [[ -n "$username" && -n "$reset_day" ]] || { err "参数不足"; return 1; }
      cmd_users_set_reset_day "$username" "$reset_day"
      ;;
    *)
      err "未知 users 子命令: ${subcmd}"
      return 1
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  local arg2="${2:-}"

  case "$cmd" in
    "")
      subflow_menu_once
      ;;
    status)
      cmd_status
      ;;
    doctor)
      cmd_doctor
      ;;
    check)
      cmd_check
      ;;
    rebuild)
      cmd_rebuild
      ;;
    --periodic-sync)
      cmd_periodic_sync
      ;;
    --daily-maintenance)
      cmd_daily_maintenance
      ;;
    --tg-agent-sync)
      return 0
      ;;
    recover)
      cmd_recover
      ;;
    install)
      cmd_install_dispatch "${@:2}"
      ;;
    update)
      cmd_update "${@:2}"
      ;;
    acme)
      cmd_acme_dispatch "${@:2}"
      ;;
    uninstall)
      warn "uninstall 仍是后续里程碑"
      return 1
      ;;
    users)
      cmd_users_dispatch "${@:2}"
      ;;
    protocol|protocols)
      cmd_protocols_dispatch "${@:2}"
      ;;
    export)
      warn "export 仍是后续里程碑"
      return 1
      ;;
    *)
      err "未知命令: ${cmd}"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
