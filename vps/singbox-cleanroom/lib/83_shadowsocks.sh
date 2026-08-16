subflow_protocol_shadowsocks_mutate_candidates() {
  local operation="$1" candidate_config="$2" candidate_meta="$3"
  local tag="$4" port="$5" method="$6"
  subflow_shadowsocks_mutator_source | python3 - "$operation" "$candidate_config" "$candidate_meta" \
    "$SUBFLOW_USERS_PATH" "$tag" "$port" "$method"
}

subflow_protocol_shadowsocks_mutate() {
  local operation="$1" tag="$2" port="$3" method="$4"
  local txn_dir candidate_config candidate_meta candidate_index
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd jq python3 || ! subflow_binary_exists; then
    subflow_lock_release
    if ! subflow_binary_exists; then subflow_fail "缺少 sing-box 二进制"; fi
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate_config="$txn_dir/config.json"
  candidate_meta="$txn_dir/meta.json"
  candidate_index="$txn_dir/subscriptions.json"
  if ! subflow_protocol_prepare_base_files "$candidate_config" "$candidate_meta" \
    || ! subflow_protocol_shadowsocks_mutate_candidates "$operation" "$candidate_config" "$candidate_meta" \
      "$tag" "$port" "$method"; then
    subflow_protocol_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_json_validate "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config" \
    || ! subflow_json_require_object "$candidate_meta" \
    || ! subflow_rebuild_generate_subscription_index_from_files \
      "$candidate_config" "$SUBFLOW_USERS_PATH" "$candidate_meta" "$candidate_index" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_protocol_discard_candidate "$txn_dir"
    subflow_fail "候选协议配置校验失败"
    return 1
  fi
  subflow_protocol_apply_candidates "$txn_dir" "$operation" "$tag" \
    "$candidate_config" "$candidate_meta" "$candidate_index"
}

cmd_protocols_add_shadowsocks_2022() {
  local tag="" port="8388" method="2022-blake3-aes-128-gcm" option value
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --tag) tag="$value" ;;
      --port) port="$value" ;;
      --method) method="$value" ;;
      *) subflow_fail "未知 Shadowsocks 2022 参数: ${option}"; return 1 ;;
    esac
    shift 2
  done
  [[ -n "$tag" ]] || { subflow_fail "缺少 --tag"; return 1; }
  case "$method" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
    *) subflow_fail "不支持的 Shadowsocks 2022 方法: ${method}"; return 1 ;;
  esac
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_shadowsocks_mutate add "$tag" "$port" "$method"
}

cmd_protocols_update_shadowsocks_2022() {
  local tag="${1:-}" port="" option value changed=0
  shift || true
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --port) port="$value" ;;
      *) subflow_fail "Shadowsocks 2022 更新仅支持 --port"; return 1 ;;
    esac
    changed=1
    shift 2
  done
  (( changed == 1 )) || { subflow_fail "没有提供更新字段"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_shadowsocks_mutate update "$tag" "$port" ""
}

cmd_protocols_delete_shadowsocks_2022() {
  local tag="${1:-}" confirmation="${2:-}"
  [[ -n "$tag" && "$#" -eq 2 && "$confirmation" == "YES" ]] \
    || { subflow_fail "用法: protocols delete <标签> YES"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_shadowsocks_mutate delete "$tag" "" ""
}