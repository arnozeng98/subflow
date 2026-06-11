#!/usr/bin/env bash

# ============================================================
# subflow VPS uninstaller
# ============================================================
# Removes the subflow service, the `sf` command and its files, while leaving the
# upstream Tangfffyx/sing-box installation and user data untouched. Can be run
# directly or via the menu (sf → 卸载).
# ============================================================

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
else
  # Minimal fallback when lib.sh is not adjacent (kept self-sufficient).
  INSTALL_ROOT="/opt/subflow"
  ENV_DIR="/etc/subflow"
  SYSTEMD_UNIT="/etc/systemd/system/subflow.service"
  SF_LINK="/usr/local/bin/sf"
  ok()   { printf '[subflow] %s\n' "$1"; }
  err()  { printf '[subflow] %s\n' "$1" >&2; }
  require_root() { [[ "${EUID}" -eq 0 ]] || { err "请使用 root 运行卸载脚本。"; exit 1; }; }
fi

require_root

systemctl stop subflow.service >/dev/null 2>&1 || true
systemctl disable subflow.service >/dev/null 2>&1 || true
rm -f "${SYSTEMD_UNIT}"
systemctl daemon-reload >/dev/null 2>&1 || true

rm -f "${SF_LINK}"
rm -rf "${INSTALL_ROOT}"
rm -rf "${ENV_DIR}"

ok "subflow 已卸载；上游 sing-box 配置与用户数据未受影响。后会有期～ (｡•́︿•̀｡)"
