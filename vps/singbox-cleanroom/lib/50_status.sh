subflow_service_file_exists() {
  local candidate
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] && return 0
  done < <(subflow_service_paths)
  return 1
}

cmd_status() {
  local platform_info pkg init arch service_state
  platform_info="$(subflow_detect_platform)" || return 1
  pkg="${platform_info%%|*}"
  init="${platform_info#*|}"
  init="${init%%|*}"
  arch="${platform_info##*|}"
  service_state="未找到"
  if subflow_service_file_exists; then
    service_state="已安装"
  fi

  banner
  step "状态"
  info "平台: 包管理器=${pkg} · init=${init} · 架构=${arch}"
  info "sing-box 二进制: ${SUBFLOW_SINGBOX_BIN} · $(subflow_key_file_state "$SUBFLOW_SINGBOX_BIN")"
  info "服务文件: ${service_state}"
  info "配置: $(subflow_key_file_state "$SUBFLOW_CONFIG_PATH")"
  info "用户库: $(subflow_key_file_state "$SUBFLOW_USERS_PATH")"
  info "元数据: $(subflow_key_file_state "$SUBFLOW_META_PATH")"
  info "订阅索引: $(subflow_key_file_state "$SUBFLOW_SUBSCRIPTION_INDEX_PATH")"
  info "密钥目录: $(subflow_key_file_state "$SUBFLOW_SECRETS_DIR")"
}
