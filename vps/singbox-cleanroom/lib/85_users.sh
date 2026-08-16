subflow_users_require_backend() {
  subflow_require_cmd jq python3
}

subflow_users_validate_username() {
  local username="$1"
  if ! subflow_is_valid_username "$username"; then
    subflow_fail "用户名不合法: ${username}"
    return 1
  fi
}

subflow_users_validate_non_negative_integer() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    subflow_fail "整数不合法: ${value}"
    return 1
  fi
}

subflow_users_validate_reset_day() {
  local value="$1"
  if ! subflow_users_validate_non_negative_integer "$value"; then
    return 1
  fi
  if [[ "$value" -lt 0 || "$value" -gt 32 ]]; then
    subflow_fail "重置日不合法: ${value}"
    return 1
  fi
}

subflow_users_validate_expire_at() {
  local value="$1"
  if [[ "$value" == "0" ]]; then
    return 0
  fi
  if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    subflow_fail "到期日期不合法: ${value}"
    return 1
  fi
  if ! python3 -c 'from datetime import date; import sys; y, m, d = map(int, sys.argv[1].split("-")); date(y, m, d)' "$value" >/dev/null 2>&1; then
    subflow_fail "到期日期不合法: ${value}"
    return 1
  fi
}

subflow_users_username_exists() {
  local username="$1"
  python3 - "$SUBFLOW_USERS_PATH" "$username" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
sys.exit(0 if sys.argv[2] in data.get('users', {}) else 1)
PY
}

subflow_users_list() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if ! subflow_users_require_backend; then
    subflow_lock_release
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi

  python3 - "$SUBFLOW_USERS_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
users = payload.get('users', {})
print('用户名 | 状态 | quota_gb | reset_day | expire_at')
for username in sorted(users):
    entry = users[username]
    enabled = '启用' if entry.get('enabled', True) else '停用'
    print(f"{username} | {enabled} | quota={entry.get('quota_gb', 0)} | reset_day={entry.get('reset_day', 0)} | expire_at={entry.get('expire_at', '0')}")
PY
  local status=$?
  subflow_lock_release
  return $status
}

subflow_users_txn_manifest_path() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/recovery.manifest.json"
}

subflow_users_txn_backup_dir() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup"
}

subflow_users_txn_users_backup() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup/users.json"
}

subflow_users_txn_index_backup() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup/subscriptions.json"
}

subflow_users_txn_config_backup() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup/config.json"
}

subflow_users_manifest_tool() {
  subflow_user_transaction_manifest_source | python3 - "$@"
}

subflow_users_txn_write_manifest() {
  local txn_dir="$1" operation="$2" username="$3"
  local users_existed="$4" index_existed="$5" config_existed="$6"
  local config_changed="$7" service_existed="$8" service_was_active="$9"
  local init="${10}" service_target="${11}" manifest_file
  manifest_file="$(subflow_users_txn_manifest_path "$txn_dir")"
  if ! subflow_users_manifest_tool write "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_USERS_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$SUBFLOW_CONFIG_PATH" \
    "$service_target" "$init" "$operation" "$username" "$users_existed" "$index_existed" \
    "$config_existed" "$config_changed" "$service_existed" "$service_was_active"; then
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_users_manifest_field() {
  local txn_dir="$1" field="$2"
  subflow_users_manifest_tool field "$(subflow_users_txn_manifest_path "$txn_dir")" "$field"
}

subflow_users_manifest_is_valid() {
  local txn_dir="$1" manifest_file version init="" expected_service_target=""
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_users_txn_manifest_path "$txn_dir")"
  if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
    subflow_fail "缺少可信用户恢复清单"
    return 1
  fi
  version="$(subflow_users_manifest_field "$txn_dir" version)" || return 1
  if [[ "$version" == "2" ]]; then
    init="$(subflow_users_manifest_field "$txn_dir" init)" || return 1
    expected_service_target="$(subflow_service_target "$init")" || return 1
  fi
  if ! subflow_users_manifest_tool validate "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_USERS_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$SUBFLOW_CONFIG_PATH" \
    "$expected_service_target"; then
    subflow_fail "非法恢复清单: ${manifest_file}"
    return 1
  fi
}

subflow_users_restore_file() {
  local existed="$1" backup_file="$2" target_file="$3"
  if [[ "$existed" == "true" ]]; then
    if [[ ! -f "$backup_file" || -L "$backup_file" ]]; then
      subflow_fail "缺少可信事务备份: ${backup_file}"
      return 1
    fi
    subflow_json_write_atomic "$target_file" "$backup_file"
  else
    rm -f "$target_file"
  fi
}

subflow_users_restore_from_manifest() {
  local txn_dir="$1" version users_existed index_existed users_backup index_backup
  local config_changed=false config_existed=false config_backup
  local init="" service_existed=false service_was_active=false
  if ! subflow_users_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  version="$(subflow_users_manifest_field "$txn_dir" version)" || return 1
  users_existed="$(subflow_users_manifest_field "$txn_dir" users_existed)" || return 1
  index_existed="$(subflow_users_manifest_field "$txn_dir" index_existed)" || return 1
  users_backup="$(subflow_users_txn_users_backup "$txn_dir")"
  index_backup="$(subflow_users_txn_index_backup "$txn_dir")"
  config_backup="$(subflow_users_txn_config_backup "$txn_dir")"
  if [[ "$version" == "2" ]]; then
    config_changed="$(subflow_users_manifest_field "$txn_dir" config_changed)" || return 1
    config_existed="$(subflow_users_manifest_field "$txn_dir" config_existed)" || return 1
    init="$(subflow_users_manifest_field "$txn_dir" init)" || return 1
    service_existed="$(subflow_users_manifest_field "$txn_dir" service_existed)" || return 1
    service_was_active="$(subflow_users_manifest_field "$txn_dir" service_was_active)" || return 1
  fi
  if [[ "$users_existed" == "true" && ( ! -f "$users_backup" || -L "$users_backup" ) ]]; then
    subflow_fail "缺少可信事务备份: ${users_backup}"
    return 1
  fi
  if [[ "$index_existed" == "true" && ( ! -f "$index_backup" || -L "$index_backup" ) ]]; then
    subflow_fail "缺少可信事务备份: ${index_backup}"
    return 1
  fi
  if [[ "$config_changed" == "true" && "$config_existed" == "true" \
    && ( ! -f "$config_backup" || -L "$config_backup" ) ]]; then
    subflow_fail "缺少可信事务备份: ${config_backup}"
    return 1
  fi
  subflow_users_restore_file "$users_existed" "$users_backup" "$SUBFLOW_USERS_PATH" || return 1
  subflow_users_restore_file "$index_existed" "$index_backup" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1
  if [[ "$config_changed" == "true" ]]; then
    subflow_users_restore_file "$config_existed" "$config_backup" "$SUBFLOW_CONFIG_PATH" || return 1
    subflow_service_reload_after_restore "$init" "$service_was_active" "$service_existed"
  fi
}

subflow_users_write_candidate_file() {
  local operation="$1"
  local source_file="$2"
  local candidate_file="$3"
  local username="$4"
  local quota_gb="${5:-}"
  local reset_day="${6:-}"
  local expire_at="${7:-}"

  case "$operation" in
    add)
      jq --arg u "$username" --argjson quota "$quota_gb" --argjson reset_day "$reset_day" --arg expire "$expire_at" '
        .schema_version = 1
        | .users[$u] = {
            enabled: true,
            disabled_reason: null,
            quota_gb: $quota,
            used_up_bytes: 0,
            used_down_bytes: 0,
            manual_added_bytes: 0,
            last_live_up_bytes: 0,
            last_live_down_bytes: 0,
            last_reset_period: "",
            reset_day: $reset_day,
            expire_at: $expire,
            allow_all_nodes: true,
            nodes: []
          }
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    enable)
      jq --arg u "$username" '
        .users[$u].enabled = true
        | .users[$u].disabled_reason = null
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    disable)
      jq --arg u "$username" '
        .users[$u].enabled = false
        | .users[$u].disabled_reason = "manual"
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    delete)
      jq --arg u "$username" '
        del(.users[$u])
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    set-quota)
      jq --arg u "$username" --argjson quota "$quota_gb" '
        .users[$u].quota_gb = $quota
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    set-expire)
      jq --arg u "$username" --arg expire "$expire_at" '
        .users[$u].expire_at = $expire
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    set-reset-day)
      jq --arg u "$username" --argjson reset_day "$reset_day" '
        (.users[$u].reset_day // 0) as $old_reset
        | .users[$u].reset_day = $reset_day
        | if $old_reset != $reset_day then .users[$u].last_reset_period = "" else . end
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    *)
      subflow_fail "未知用户操作: ${operation}"
      return 1
      ;;
  esac
}

subflow_users_operation_changes_config() {
  case "$1" in
    add|enable|disable|delete) return 0 ;;
    *) return 1 ;;
  esac
}

subflow_users_write_candidate_config() {
  local operation="$1" candidate_config="$2" candidate_users="$3" username="$4"
  cp "$SUBFLOW_CONFIG_PATH" "$candidate_config" || return 1
  subflow_user_config_mutator_source | python3 - "$operation" "$candidate_config" "$candidate_users" "$username"
}

subflow_users_discard_candidate() {
  local txn_dir="$1"
  subflow_txn_abort "$txn_dir" || true
  subflow_lock_release
}

subflow_users_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_users_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧状态"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_users_apply_mutation() {
  local operation="$1"
  local username="$2"
  local quota_gb="${3:-}"
  local reset_day="${4:-}"
  local expire_at="${5:-}"
  local txn_dir candidate_users candidate_config candidate_index
  local users_existed index_existed config_existed
  local config_changed=false service_existed=false service_was_active=false
  local init service_target

  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi

  if ! subflow_users_require_backend; then
    subflow_lock_release
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi
  if [[ -e "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]]; then
    if ! subflow_json_require_schema_v1 "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"; then
      subflow_lock_release
      return 1
    fi
  fi
  if ! subflow_json_require_object "$SUBFLOW_CONFIG_PATH" \
    || ! subflow_check_config_file "$SUBFLOW_CONFIG_PATH" \
    || ! subflow_json_require_object "$SUBFLOW_META_PATH"; then
    subflow_lock_release
    return 1
  fi
  if ! subflow_binary_exists; then
    subflow_lock_release
    subflow_fail "缺少 sing-box 二进制"
    return 1
  fi

  if ! subflow_users_validate_username "$username"; then
    subflow_lock_release
    return 1
  fi

  case "$operation" in
    add)
      if [[ "$username" == "admin" ]]; then
        subflow_lock_release
        subflow_fail "admin 不能新增"
        return 1
      fi
      if ! subflow_users_validate_non_negative_integer "$quota_gb"; then
        subflow_lock_release
        return 1
      fi
      if ! subflow_users_validate_reset_day "$reset_day"; then
        subflow_lock_release
        return 1
      fi
      if ! subflow_users_validate_expire_at "$expire_at"; then
        subflow_lock_release
        return 1
      fi
      if subflow_users_username_exists "$username"; then
        subflow_lock_release
        subflow_fail "用户已存在: ${username}"
        return 1
      fi
      ;;
    enable|disable|set-quota|set-expire|set-reset-day|delete)
      if ! subflow_users_username_exists "$username"; then
        subflow_lock_release
        subflow_fail "未知用户: ${username}"
        return 1
      fi
      ;;
  esac

  if [[ "$operation" == "delete" && "$username" == "admin" ]]; then
    subflow_lock_release
    subflow_fail "admin 不能删除"
    return 1
  fi

  case "$operation" in
    set-quota)
      if ! subflow_users_validate_non_negative_integer "$quota_gb"; then
        subflow_lock_release
        return 1
      fi
      ;;
    set-expire)
      if ! subflow_users_validate_expire_at "$expire_at"; then
        subflow_lock_release
        return 1
      fi
      ;;
    set-reset-day)
      if ! subflow_users_validate_reset_day "$reset_day"; then
        subflow_lock_release
        return 1
      fi
      ;;
  esac

  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || {
      subflow_lock_release
      return 1
    }
  fi
  service_target="$(subflow_service_target "$init")" || {
    subflow_lock_release
    return 1
  }
  if [[ -f "$service_target" ]]; then
    service_existed=true
    if subflow_service_is_active "$init"; then
      service_was_active=true
    fi
  fi
  if subflow_users_operation_changes_config "$operation"; then
    config_changed=true
    if [[ "$service_existed" != "true" ]]; then
      subflow_lock_release
      subflow_fail "sing-box 服务定义缺失: ${service_target}"
      return 1
    fi
  fi

  if ! txn_dir="$(subflow_txn_dir_create)"; then
    subflow_lock_release
    return 1
  fi
  candidate_users="${txn_dir}/users.json"
  candidate_config="${txn_dir}/config.json"
  candidate_index="${txn_dir}/subscriptions.json"
  users_existed="false"
  index_existed="false"
  config_existed="false"
  [[ -f "$SUBFLOW_USERS_PATH" ]] && users_existed="true"
  [[ -f "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]] && index_existed="true"
  [[ -f "$SUBFLOW_CONFIG_PATH" ]] && config_existed="true"

  if ! subflow_users_write_candidate_file "$operation" "$SUBFLOW_USERS_PATH" "$candidate_users" "$username" "$quota_gb" "$reset_day" "$expire_at"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_users_write_candidate_config "$operation" "$candidate_config" "$candidate_users" "$username" \
    || ! subflow_json_require_schema_v1 "$candidate_users" \
    || ! subflow_json_require_object "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_rebuild_generate_subscription_index_from_files \
    "$candidate_config" "$candidate_users" "$SUBFLOW_META_PATH" "$candidate_index" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_users_discard_candidate "$txn_dir"
    subflow_fail "候选用户配置校验失败，未写入现有状态"
    return 1
  fi

  if ! mkdir -p "$(subflow_users_txn_backup_dir "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$users_existed" == "true" ]] \
    && ! cp "$SUBFLOW_USERS_PATH" "$(subflow_users_txn_users_backup "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$index_existed" == "true" ]] \
    && ! cp "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$(subflow_users_txn_index_backup "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$config_changed" == "true" ]] \
    && ! cp "$SUBFLOW_CONFIG_PATH" "$(subflow_users_txn_config_backup "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  chmod 600 "$(subflow_users_txn_backup_dir "$txn_dir")"/* 2>/dev/null || true

  if ! subflow_users_txn_write_manifest "$txn_dir" "$operation" "$username" \
    "$users_existed" "$index_existed" "$config_existed" "$config_changed" \
    "$service_existed" "$service_was_active" "$init" "$service_target" \
    || ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  if ! subflow_json_write_atomic "$SUBFLOW_USERS_PATH" "$candidate_users"; then
    subflow_users_rollback "$txn_dir" "用户库写入失败"
    return 1
  fi
  if [[ "$config_changed" == "true" ]] \
    && ! subflow_json_write_atomic "$SUBFLOW_CONFIG_PATH" "$candidate_config"; then
    subflow_users_rollback "$txn_dir" "sing-box 用户配置写入失败"
    return 1
  fi
  if ! subflow_json_write_atomic "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$candidate_index"; then
    subflow_users_rollback "$txn_dir" "订阅索引写入失败"
    return 1
  fi
  if [[ "$config_changed" == "true" ]] \
    && ! subflow_service_apply_config_transaction "$init" "$service_was_active"; then
    subflow_users_rollback "$txn_dir" "sing-box 用户配置应用失败"
    return 1
  fi

  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "用户 ${username} 已更新"
}

cmd_users_add() {
  local username="$1"
  local quota_gb="$2"
  local reset_day="$3"
  local expire_at="$4"
  subflow_users_apply_mutation add "$username" "$quota_gb" "$reset_day" "$expire_at"
}

cmd_users_enable() {
  subflow_users_apply_mutation enable "$1"
}

cmd_users_disable() {
  subflow_users_apply_mutation disable "$1"
}

cmd_users_delete() {
  subflow_users_apply_mutation delete "$1"
}

cmd_users_set_quota() {
  subflow_users_apply_mutation set-quota "$1" "$2"
}

cmd_users_set_expire() {
  subflow_users_apply_mutation set-expire "$1" "" "" "$2"
}

cmd_users_set_reset_day() {
  subflow_users_apply_mutation set-reset-day "$1" "" "$2"
}
