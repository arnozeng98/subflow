subflow_check_users_file() {
  local file="$1"
  if ! jq -e 'type == "object" and .schema_version == 1 and (.users | type == "object")' "$file" >/dev/null; then
    subflow_fail "用户库结构错误: ${file}"
    return 1
  fi
}

subflow_check_meta_file() {
  local file="$1"
  if ! jq -e 'type == "object"' "$file" >/dev/null; then
    subflow_fail "元数据结构错误: ${file}"
    return 1
  fi
}

subflow_check_config_file() {
  local file="$1"
  if ! jq -e 'type == "object" and (.inbounds | type == "array")' "$file" >/dev/null; then
    subflow_fail "配置结构错误: ${file}"
    return 1
  fi
}

subflow_check_subscription_index_file() {
  local file="$1"
  if ! jq -e 'type == "object" and .schema_version == 1 and (.users | type == "object")' "$file" >/dev/null; then
    subflow_fail "订阅索引结构错误: ${file}"
    return 1
  fi
}

cmd_check() {
  subflow_require_cmd jq || return 1
  subflow_json_require_file "$SUBFLOW_CONFIG_PATH" || return 1
  subflow_json_require_file "$SUBFLOW_USERS_PATH" || return 1
  subflow_json_require_file "$SUBFLOW_META_PATH" || return 1
  subflow_json_require_file "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1

  subflow_json_validate "$SUBFLOW_CONFIG_PATH" || return 1
  subflow_json_validate "$SUBFLOW_USERS_PATH" || return 1
  subflow_json_validate "$SUBFLOW_META_PATH" || return 1
  subflow_json_validate "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1

  subflow_check_config_file "$SUBFLOW_CONFIG_PATH" || return 1
  subflow_check_users_file "$SUBFLOW_USERS_PATH" || return 1
  subflow_check_meta_file "$SUBFLOW_META_PATH" || return 1
  subflow_check_subscription_index_file "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1

  if subflow_binary_exists; then
    "$SUBFLOW_SINGBOX_BIN" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null
  else
    subflow_fail "缺少 sing-box 二进制"
    return 1
  fi
}

cmd_periodic_sync() {
  cmd_rebuild
}

cmd_daily_maintenance() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if ! subflow_txn_cleanup_stale; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "daily-maintenance 完成"
}

cmd_tg_agent_sync() {
  return 0
}
