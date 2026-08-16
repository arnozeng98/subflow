#!/usr/bin/env bash
# ============================================================
# subflow 共享终端主题
# ============================================================
# 所有部署与管理脚本共用的颜色、状态输出、暂停提示和品牌横幅。
# ============================================================

setup_colors() {
  local ncolors=0
  if command -v tput >/dev/null 2>&1; then
    ncolors="$(tput colors 2>/dev/null || printf '0')"
  fi
  if [[ -t 1 && "${ncolors}" -ge 8 && "${NO_COLOR:-}" == "" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_PINK=$'\033[38;5;218m'
    C_LAV=$'\033[38;5;183m'
    C_CYAN=$'\033[38;5;117m'
    C_GREEN=$'\033[38;5;151m'
    C_YELLOW=$'\033[38;5;229m'
    C_RED=$'\033[38;5;210m'
    C_GREY=$'\033[38;5;246m'
  else
    C_RESET="" C_BOLD="" C_DIM="" C_PINK="" C_LAV="" C_CYAN=""
    C_GREEN="" C_YELLOW="" C_RED="" C_GREY=""
  fi
}
setup_colors

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

banner() {
  printf '%b\n' ""
  printf '%b\n' "${C_PINK}  ███████╗██╗   ██╗██████╗ ███████╗██╗      ██████╗ ██╗    ██╗${C_RESET}"
  printf '%b\n' "${C_PINK}  ██╔════╝██║   ██║██╔══██╗██╔════╝██║     ██╔═══██╗██║    ██║${C_RESET}"
  printf '%b\n' "${C_LAV}  ███████╗██║   ██║██████╔╝█████╗  ██║     ██║   ██║██║ █╗ ██║${C_RESET}"
  printf '%b\n' "${C_LAV}  ╚════██║██║   ██║██╔══██╗██╔══╝  ██║     ██║   ██║██║███╗██║${C_RESET}"
  printf '%b\n' "${C_CYAN}  ███████║╚██████╔╝██████╔╝██║     ███████╗╚██████╔╝╚███╔███╔╝${C_RESET}"
  printf '%b\n' "${C_CYAN}  ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝ ${C_RESET}"
  printf '%b\n' ""
  printf '%b\n' "  ${C_BOLD}SUBFLOW${C_RESET} ${C_GREY}· 由 Cloudflare 提供前端的逐用户 sing-box 订阅${C_RESET}"
  printf '%b\n' "  ${C_PINK}♡${C_RESET} ${C_BOLD}作者${C_RESET} ${C_LAV}${AUTHOR:-未知}${C_RESET}   ${C_PINK}♡${C_RESET} ${C_BOLD}仓库${C_RESET} ${C_CYAN}${REPO_URL:-未设置}${C_RESET}"
  printf '%b\n' "  ${C_GREY}────────────────────────────────────────────────────${C_RESET}"
}
