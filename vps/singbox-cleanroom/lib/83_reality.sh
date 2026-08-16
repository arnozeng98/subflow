subflow_protocol_reality_generate_keypair() {
  local output line private_key="" public_key="" value
  output="$("$SUBFLOW_SINGBOX_BIN" generate reality-keypair 2>&1)" || {
    subflow_fail "生成 Reality 密钥对失败"
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      PrivateKey:*)
        value="${line#*:}"
        private_key="${value#"${value%%[![:space:]]*}"}"
        ;;
      PublicKey:*)
        value="${line#*:}"
        public_key="${value#"${value%%[![:space:]]*}"}"
        ;;
    esac
  done <<<"$output"
  if [[ ! "$private_key" =~ ^[A-Za-z0-9_-]{40,64}$ || ! "$public_key" =~ ^[A-Za-z0-9_-]{40,64}$ ]]; then
    subflow_fail "Reality 密钥对输出格式无效"
    return 1
  fi
  printf '%s\n%s\n' "$private_key" "$public_key"
}

subflow_protocol_reality_generate_short_id() {
  local short_id
  short_id="$(openssl rand -hex 8)" || return 1
  if [[ ! "$short_id" =~ ^[0-9A-Fa-f]{16}$ ]]; then
    subflow_fail "生成 Reality short ID 失败"
    return 1
  fi
  printf '%s\n' "${short_id,,}"
}

subflow_protocol_prepare_base_files() {
  local candidate_config="$1" candidate_meta="$2"
  if [[ -f "$SUBFLOW_CONFIG_PATH" ]]; then
    subflow_json_require_object "$SUBFLOW_CONFIG_PATH" || return 1
    subflow_check_config_file "$SUBFLOW_CONFIG_PATH" || return 1
    cp "$SUBFLOW_CONFIG_PATH" "$candidate_config" || return 1
  else
    cat >"$candidate_config" <<'JSON'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON
  fi
  if [[ -f "$SUBFLOW_META_PATH" ]]; then
    subflow_json_require_object "$SUBFLOW_META_PATH" || return 1
    cp "$SUBFLOW_META_PATH" "$candidate_meta" || return 1
  else
    printf '{}\n' >"$candidate_meta"
  fi
}

subflow_protocol_reality_mutate_candidates() {
  local operation="$1" candidate_config="$2" candidate_meta="$3" tag="$4"
  local port="$5" server_name="$6" handshake_server="$7" handshake_port="$8"
  local private_key="$9" public_key="${10}" short_id="${11}"
  subflow_reality_mutator_source | python3 - "$operation" "$candidate_config" "$candidate_meta" \
    "$SUBFLOW_USERS_PATH" "$tag" "$port" "$server_name" "$handshake_server" \
    "$handshake_port" "$private_key" "$public_key" "$short_id"
}

subflow_protocol_discard_candidate() {
  local txn_dir="$1"
  subflow_txn_abort "$txn_dir" || true
  subflow_lock_release
}

subflow_protocol_vless_reality_mutate() {
  local operation="$1" tag="$2" port="$3" server_name="$4"
  local handshake_server="$5" handshake_port="$6"
  local txn_dir candidate_config candidate_meta candidate_index short_id="" private_key="" public_key=""
  local -a keypair=()

  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd jq python3 openssl || ! subflow_binary_exists; then
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
  if ! subflow_protocol_prepare_base_files "$candidate_config" "$candidate_meta"; then
    subflow_protocol_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$operation" == "add" ]]; then
    if ! mapfile -t keypair < <(subflow_protocol_reality_generate_keypair) || [[ ${#keypair[@]} -ne 2 ]]; then
      subflow_protocol_discard_candidate "$txn_dir"
      return 1
    fi
    private_key="${keypair[0]}"
    public_key="${keypair[1]}"
    short_id="$(subflow_protocol_reality_generate_short_id)" || {
      subflow_protocol_discard_candidate "$txn_dir"
      return 1
    }
  fi
  if ! subflow_protocol_reality_mutate_candidates "$operation" "$candidate_config" "$candidate_meta" \
    "$tag" "$port" "$server_name" "$handshake_server" "$handshake_port" \
    "$private_key" "$public_key" "$short_id"; then
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

cmd_protocols_add_vless_reality() {
  local tag="" port="443" server_name="" handshake_server="" handshake_port="443"
  local option value
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --tag) tag="$value" ;;
      --port) port="$value" ;;
      --server-name) server_name="$value" ;;
      --handshake-server) handshake_server="$value" ;;
      --handshake-port) handshake_port="$value" ;;
      *) subflow_fail "未知 protocols add 参数: ${option}"; return 1 ;;
    esac
    shift 2
  done
  [[ -n "$tag" ]] || { subflow_fail "缺少 --tag"; return 1; }
  [[ -n "$server_name" ]] || { subflow_fail "缺少 --server-name"; return 1; }
  [[ -n "$handshake_server" ]] || handshake_server="$server_name"
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_validate_port "$handshake_port" || return 1
  subflow_protocol_validate_server_name "$server_name" || return 1
  subflow_protocol_validate_server_name "$handshake_server" || return 1
  subflow_protocol_vless_reality_mutate add "$tag" "$port" "$server_name" "$handshake_server" "$handshake_port"
}

cmd_protocols_update_vless_reality() {
  local tag="${1:-}" port="" server_name="" handshake_server="" handshake_port="" option value changed=0
  shift || true
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --port) port="$value" ;;
      --server-name) server_name="$value" ;;
      --handshake-server) handshake_server="$value" ;;
      --handshake-port) handshake_port="$value" ;;
      *) subflow_fail "未知 protocols update 参数: ${option}"; return 1 ;;
    esac
    changed=1
    shift 2
  done
  (( changed == 1 )) || { subflow_fail "没有提供更新字段"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  [[ -z "$port" ]] || subflow_protocol_validate_port "$port" || return 1
  [[ -z "$handshake_port" ]] || subflow_protocol_validate_port "$handshake_port" || return 1
  [[ -z "$server_name" ]] || subflow_protocol_validate_server_name "$server_name" || return 1
  [[ -z "$handshake_server" ]] || subflow_protocol_validate_server_name "$handshake_server" || return 1
  subflow_protocol_vless_reality_mutate update "$tag" "$port" "$server_name" "$handshake_server" "$handshake_port"
}

cmd_protocols_delete_vless_reality() {
  local tag="${1:-}" confirmation="${2:-}"
  [[ -n "$tag" && "$#" -eq 2 && "$confirmation" == "YES" ]] \
    || { subflow_fail "用法: protocols delete <标签> YES"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_vless_reality_mutate delete "$tag" "" "" "" ""
}