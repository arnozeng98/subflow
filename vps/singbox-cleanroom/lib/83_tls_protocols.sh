subflow_protocol_tls_mutate_candidates() {
  local operation="$1" protocol="$2" candidate_config="$3" candidate_meta="$4"
  local tag="$5" port="$6" domain="$7" email="$8"
  subflow_tls_protocol_mutator_source | python3 - "$operation" "$protocol" \
    "$candidate_config" "$candidate_meta" "$SUBFLOW_USERS_PATH" \
    "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$SUBFLOW_ACME_DATA_DIR" \
    "$tag" "$port" "$domain" "$email"
}

subflow_protocol_tls_mutate() {
  local operation="$1" protocol="$2" tag="$3" port="$4" domain="$5" email="$6"
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
  if [[ "$operation" != "delete" ]] && ! subflow_acme_cloudflare_validate; then
    subflow_lock_release
    subflow_fail "请先导入 Cloudflare ACME 凭据"
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
    || ! subflow_protocol_tls_mutate_candidates "$operation" "$protocol" \
      "$candidate_config" "$candidate_meta" "$tag" "$port" "$domain" "$email"; then
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
    subflow_fail "候选 TLS 协议配置校验失败"
    return 1
  fi
  subflow_protocol_apply_candidates "$txn_dir" "$operation" "$tag" \
    "$candidate_config" "$candidate_meta" "$candidate_index"
}

cmd_protocols_add_tls() {
  local protocol="$1" tag="" port="443" domain="" email="" option value
  shift || true
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --tag) tag="$value" ;;
      --port) port="$value" ;;
      --domain) domain="$value" ;;
      --email) email="$value" ;;
      *) subflow_fail "未知 ${protocol} 参数: ${option}"; return 1 ;;
    esac
    shift 2
  done
  [[ -n "$tag" ]] || { subflow_fail "缺少 --tag"; return 1; }
  [[ -n "$domain" ]] || { subflow_fail "缺少 --domain"; return 1; }
  [[ -n "$email" ]] || { subflow_fail "缺少 --email"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_validate_server_name "$domain" || return 1
  subflow_protocol_validate_email "$email" || return 1
  subflow_protocol_tls_mutate add "$protocol" "$tag" "$port" "$domain" "$email"
}

cmd_protocols_update_tls() {
  local protocol="$1" tag="$2" port="" domain="" email="" option value changed=0
  shift 2 || true
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --port) port="$value" ;;
      --domain) domain="$value" ;;
      --email) email="$value" ;;
      *) subflow_fail "未知 ${protocol} 更新参数: ${option}"; return 1 ;;
    esac
    changed=1
    shift 2
  done
  (( changed == 1 )) || { subflow_fail "没有提供更新字段"; return 1; }
  [[ -z "$port" ]] || subflow_protocol_validate_port "$port" || return 1
  [[ -z "$domain" ]] || subflow_protocol_validate_server_name "$domain" || return 1
  [[ -z "$email" ]] || subflow_protocol_validate_email "$email" || return 1
  subflow_protocol_tls_mutate update "$protocol" "$tag" "$port" "$domain" "$email"
}

cmd_protocols_delete_tls() {
  local protocol="$1" tag="$2" confirmation="${3:-}"
  [[ "$#" -eq 3 && "$confirmation" == "YES" ]] \
    || { subflow_fail "用法: protocols delete <标签> YES"; return 1; }
  subflow_protocol_tls_mutate delete "$protocol" "$tag" "" "" ""
}