subflow_acme_secret_tool() {
  subflow_acme_secret_source | python3 - "$@"
}

subflow_acme_cloudflare_validate() {
  subflow_acme_secret_tool validate "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH"
}

subflow_acme_cloudflare_field() {
  subflow_acme_secret_tool field "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$1"
}

subflow_acme_config_state() {
  subflow_acme_secret_tool config-state "$SUBFLOW_CONFIG_PATH"
}

subflow_acme_rotation_manifest_path() {
  printf '%s\n' "$1/acme-rotation.manifest.json"
}

subflow_acme_rotation_manifest_field() {
  local txn_dir="$1" field="$2"
  subflow_acme_secret_tool rotation-manifest-field \
    "$(subflow_acme_rotation_manifest_path "$txn_dir")" "$field"
}

subflow_acme_rotation_write_manifest() {
  local txn_dir="$1" init="$2" service_target="$3"
  local secret_existed="$4" service_was_active="$5" manifest_file
  manifest_file="$(subflow_acme_rotation_manifest_path "$txn_dir")"
  if ! subflow_acme_secret_tool rotation-manifest-write \
    "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" "$SUBFLOW_CONFIG_PATH" \
    "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$service_target" "$init" \
    "$secret_existed" "$service_was_active"; then
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_acme_rotation_manifest_is_valid() {
  local txn_dir="$1" manifest_file init expected_service_target
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_acme_rotation_manifest_path "$txn_dir")"
  if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
    subflow_fail "缺少可信 ACME 轮换清单"
    return 1
  fi
  init="$(subflow_acme_rotation_manifest_field "$txn_dir" init)" || return 1
  expected_service_target="$(subflow_service_target "$init")" || return 1
  if ! subflow_acme_secret_tool rotation-manifest-validate \
    "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" "$SUBFLOW_CONFIG_PATH" \
    "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$expected_service_target"; then
    subflow_fail "非法 ACME 轮换清单: ${manifest_file}"
    return 1
  fi
}

subflow_acme_rotation_restore_from_manifest() {
  local txn_dir="$1" backup_dir init secret_existed service_was_active
  local config_backup secret_backup
  if ! subflow_acme_rotation_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  backup_dir="$txn_dir/backup"
  config_backup="$backup_dir/config.json"
  secret_backup="$backup_dir/cloudflare-acme.json"
  init="$(subflow_acme_rotation_manifest_field "$txn_dir" init)" || return 1
  secret_existed="$(subflow_acme_rotation_manifest_field "$txn_dir" secret_existed)" || return 1
  service_was_active="$(subflow_acme_rotation_manifest_field "$txn_dir" service_was_active)" || return 1
  if [[ ! -f "$config_backup" || -L "$config_backup" ]]; then
    subflow_fail "缺少可信 ACME 配置备份: ${config_backup}"
    return 1
  fi
  if [[ "$secret_existed" == "true" && ( ! -f "$secret_backup" || -L "$secret_backup" ) ]]; then
    subflow_fail "缺少可信 ACME 凭据备份: ${secret_backup}"
    return 1
  fi
  subflow_file_write_atomic "$SUBFLOW_CONFIG_PATH" "$config_backup" 600 || return 1
  if [[ "$secret_existed" == "true" ]]; then
    subflow_file_write_atomic "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$secret_backup" 600 || return 1
  else
    rm -f "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" || return 1
  fi
  subflow_service_reload_after_restore "$init" "$service_was_active" true
}

subflow_acme_rotation_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_acme_rotation_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧凭据和配置"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_acme_cloudflare_rotate() {
  local txn_dir="$1" candidate_secret="$2"
  local candidate_config backup_dir init service_target
  local secret_existed=false service_was_active=false
  candidate_config="$txn_dir/config.json"
  backup_dir="$txn_dir/backup"
  if ! subflow_require_cmd python3 || ! subflow_binary_exists; then
    if ! subflow_binary_exists; then subflow_fail "缺少 sing-box 二进制"; fi
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  service_target="$(subflow_service_target "$init")" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  if [[ ! -f "$service_target" ]]; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "sing-box 服务定义缺失: ${service_target}"
    return 1
  fi
  if subflow_service_is_active "$init"; then service_was_active=true; fi
  if [[ -L "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" ]]; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "Cloudflare ACME 凭据路径不能是符号链接"
    return 1
  fi
  [[ -f "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" ]] && secret_existed=true

  if ! subflow_acme_secret_tool rewrite-config \
    "$SUBFLOW_CONFIG_PATH" "$candidate_secret" "$candidate_config" \
    || ! subflow_json_require_object "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "候选 ACME 配置校验失败，未写入现有状态"
    return 1
  fi
  if ! mkdir -p "$backup_dir" \
    || ! cp "$SUBFLOW_CONFIG_PATH" "$backup_dir/config.json" \
    || { [[ "$secret_existed" == "true" ]] \
      && ! cp "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$backup_dir/cloudflare-acme.json"; }; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  chmod 600 "$backup_dir"/* 2>/dev/null || true
  if ! subflow_acme_rotation_write_manifest \
    "$txn_dir" "$init" "$service_target" "$secret_existed" "$service_was_active" \
    || ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  if ! subflow_file_write_atomic "$SUBFLOW_CONFIG_PATH" "$candidate_config" 600 \
    || ! subflow_file_write_atomic "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$candidate_secret" 600; then
    subflow_acme_rotation_rollback "$txn_dir" "ACME 轮换文件写入失败"
    return 1
  fi
  if ! subflow_service_apply_config_transaction "$init" "$service_was_active"; then
    subflow_acme_rotation_rollback "$txn_dir" "ACME 轮换服务应用失败"
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "Cloudflare ACME 凭据已在线轮换"
}

subflow_acme_cloudflare_import() {
  local api_token_file="$1" zone_token_file="${2:--}" txn_dir candidate config_state
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd python3; then
    subflow_lock_release
    return 1
  fi
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate="$txn_dir/cloudflare-acme.json"
  if ! mkdir -p "$SUBFLOW_SECRETS_DIR" "$SUBFLOW_ACME_DATA_DIR" \
    || ! subflow_acme_secret_tool create "$api_token_file" "$zone_token_file" "$candidate"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  chmod 700 "$SUBFLOW_SECRETS_DIR" "$SUBFLOW_ACME_DATA_DIR" 2>/dev/null || true
  config_state="$(subflow_acme_config_state)" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  if [[ "$config_state" == "used" ]]; then
    subflow_acme_cloudflare_rotate "$txn_dir" "$candidate"
    return $?
  fi
  if ! subflow_file_write_atomic "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$candidate" 600; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  subflow_txn_abort "$txn_dir" || true
  subflow_lock_release
  ok "Cloudflare ACME 凭据已导入"
}

subflow_acme_status() {
  if subflow_acme_cloudflare_validate >/dev/null 2>&1; then
    info "Cloudflare DNS-01: 已配置"
  else
    info "Cloudflare DNS-01: 未配置"
  fi
}

subflow_acme_clear() {
  local confirmation="$1"
  [[ "$confirmation" == "YES" ]] || {
    subflow_fail "清除 ACME 凭据必须输入 YES"
    return 1
  }
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  local config_state
  config_state="$(subflow_acme_config_state)" || {
    subflow_lock_release
    return 1
  }
  if [[ "$config_state" == "used" ]]; then
    subflow_lock_release
    subflow_fail "请先删除使用 Cloudflare ACME 的 TLS 协议"
    return 1
  fi
  if ! rm -f "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "Cloudflare ACME 凭据已清除"
}

cmd_acme_dispatch() {
  local subcmd="${1:-status}"
  shift || true
  case "$subcmd" in
    status)
      [[ "$#" -eq 0 ]] || { subflow_fail "acme status 不接受参数"; return 1; }
      subflow_acme_status
      ;;
    import-cloudflare)
      [[ "$#" -ge 1 && "$#" -le 2 ]] \
        || { subflow_fail "用法: acme import-cloudflare <api-token-file> [zone-token-file]"; return 1; }
      subflow_acme_cloudflare_import "$@"
      ;;
    clear)
      [[ "$#" -eq 1 ]] || { subflow_fail "用法: acme clear YES"; return 1; }
      subflow_acme_clear "$1"
      ;;
    *)
      subflow_fail "未知 acme 子命令: ${subcmd}"
      return 1
      ;;
  esac
}