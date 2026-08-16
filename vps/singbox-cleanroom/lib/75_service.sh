subflow_service_validate_exec_paths() {
  if [[ "$SUBFLOW_SINGBOX_BIN" =~ [[:space:]] || "$SUBFLOW_CONFIG_PATH" =~ [[:space:]] ]]; then
    subflow_fail "服务路径不能包含空白字符"
    return 1
  fi
}

subflow_service_target() {
  local init="$1"
  case "$init" in
    systemd) printf '%s\n' "$SUBFLOW_SYSTEMD_UNIT_PATH" ;;
    openrc) printf '%s\n' "$SUBFLOW_OPENRC_SERVICE_PATH" ;;
    *)
      subflow_fail "不支持的 init 系统: ${init}"
      return 1
      ;;
  esac
}

subflow_service_is_active() {
  local init="$1"
  case "$init" in
    systemd) systemctl is-active --quiet "$SUBFLOW_SERVICE_NAME" ;;
    openrc) rc-service "$SUBFLOW_SERVICE_NAME" status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

subflow_service_write_definition() {
  local init="$1" target source_file
  subflow_service_validate_exec_paths || return 1
  target="$(subflow_service_target "$init")" || return 1
  source_file="$(mktemp)" || return 1

  case "$init" in
    systemd)
      cat >"$source_file" <<EOF
[Unit]
Description=sing-box service managed by subflow
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SUBFLOW_SINGBOX_BIN} run -c ${SUBFLOW_CONFIG_PATH}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      if ! subflow_file_write_atomic "$target" "$source_file" 644; then
        rm -f "$source_file"
        return 1
      fi
      ;;
    openrc)
      cat >"$source_file" <<EOF
#!/sbin/openrc-run
description="sing-box service managed by subflow"
command="${SUBFLOW_SINGBOX_BIN}"
command_args="run -c ${SUBFLOW_CONFIG_PATH}"
command_background="yes"
pidfile="/run/${SUBFLOW_SERVICE_NAME}.pid"

depend() {
  need net
  after firewall
}
EOF
      if ! subflow_file_write_atomic "$target" "$source_file" 755; then
        rm -f "$source_file"
        return 1
      fi
      ;;
  esac
  rm -f "$source_file"
}

subflow_service_enable_and_restart() {
  local init="$1"
  case "$init" in
    systemd)
      systemctl daemon-reload || return 1
      systemctl enable "$SUBFLOW_SERVICE_NAME" >/dev/null || return 1
      if subflow_service_is_active "$init"; then
        systemctl restart "$SUBFLOW_SERVICE_NAME" || return 1
      else
        systemctl start "$SUBFLOW_SERVICE_NAME" || return 1
      fi
      ;;
    openrc)
      rc-update add "$SUBFLOW_SERVICE_NAME" default >/dev/null || return 1
      if subflow_service_is_active "$init"; then
        rc-service "$SUBFLOW_SERVICE_NAME" restart || return 1
      else
        rc-service "$SUBFLOW_SERVICE_NAME" start || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  subflow_service_is_active "$init"
}

subflow_service_apply_config_transaction() {
  local init="$1" was_active="$2"
  case "$init" in
    systemd)
      systemctl daemon-reload || return 1
      if [[ "$was_active" == "true" ]]; then
        systemctl restart "$SUBFLOW_SERVICE_NAME" || return 1
      else
        systemctl start "$SUBFLOW_SERVICE_NAME" || return 1
      fi
      ;;
    openrc)
      if [[ "$was_active" == "true" ]]; then
        rc-service "$SUBFLOW_SERVICE_NAME" restart || return 1
      else
        rc-service "$SUBFLOW_SERVICE_NAME" start || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  subflow_service_is_active "$init" || return 1
  if [[ "$was_active" != "true" ]]; then
    case "$init" in
      systemd) systemctl stop "$SUBFLOW_SERVICE_NAME" || return 1 ;;
      openrc) rc-service "$SUBFLOW_SERVICE_NAME" stop || return 1 ;;
    esac
  fi
}

subflow_service_reload_after_restore() {
  local init="$1" was_active="$2" service_existed="$3"
  case "$init" in
    systemd)
      if [[ "$was_active" != "true" ]]; then
        systemctl stop "$SUBFLOW_SERVICE_NAME" >/dev/null 2>&1 || true
      fi
      systemctl daemon-reload || return 1
      if [[ "$service_existed" != "true" ]]; then
        systemctl disable "$SUBFLOW_SERVICE_NAME" >/dev/null 2>&1 || true
      fi
      ;;
    openrc)
      if [[ "$was_active" != "true" ]]; then
        rc-service "$SUBFLOW_SERVICE_NAME" stop >/dev/null 2>&1 || true
      fi
      if [[ "$service_existed" != "true" ]]; then
        rc-update del "$SUBFLOW_SERVICE_NAME" default >/dev/null 2>&1 || true
      fi
      ;;
    *) return 1 ;;
  esac
  if [[ "$was_active" == "true" ]]; then
    case "$init" in
      systemd) systemctl restart "$SUBFLOW_SERVICE_NAME" ;;
      openrc) rc-service "$SUBFLOW_SERVICE_NAME" restart ;;
    esac
  fi
}