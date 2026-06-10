#!/usr/bin/env bash

# ============================================================
# subflow VPS uninstaller
# ============================================================
# This script removes the local subflow service while intentionally leaving the
# upstream Tangfffyx/sing-box installation untouched. The operator can therefore
# roll back subflow without risking the actual proxy service state.
# ============================================================

set -Eeuo pipefail

say() {
  printf '[subflow] %s\n' "$1"
}

if [[ "${EUID}" -ne 0 ]]; then
  say "请使用 root 运行卸载脚本。"
  exit 1
fi

systemctl stop subflow.service >/dev/null 2>&1 || true
systemctl disable subflow.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/subflow.service
systemctl daemon-reload >/dev/null 2>&1 || true

rm -rf /opt/subflow
rm -rf /etc/subflow

say "subflow 已卸载；上游 sing-box 配置与用户数据未受影响。"