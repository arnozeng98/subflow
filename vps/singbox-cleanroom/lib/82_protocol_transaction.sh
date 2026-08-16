subflow_protocol_txn_manifest_path() {
  printf '%s\n' "$1/protocol.manifest.json"
}

subflow_protocol_txn_write_manifest() {
  local txn_dir="$1" operation="$2" tag="$3" init="$4"
  local config_existed="$5" meta_existed="$6" index_existed="$7"
  local service_existed="$8" service_was_active="$9"
  local manifest_file service_target
  manifest_file="$(subflow_protocol_txn_manifest_path "$txn_dir")"
  service_target="$(subflow_service_target "$init")" || return 1

  python3 - "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_CONFIG_PATH" "$SUBFLOW_META_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" \
    "$service_target" "$operation" "$tag" "$init" "$config_existed" "$meta_existed" \
    "$index_existed" "$service_existed" "$service_was_active" <<'PY'
import json
import sys
from pathlib import Path


def boolean(value):
    if value not in {"true", "false"}:
        raise ValueError("invalid boolean")
    return value == "true"


(
    manifest_file,
    txn_dir,
    state_dir,
    config_target,
    meta_target,
    index_target,
    service_target,
    operation,
    tag,
    init,
    config_existed,
    meta_existed,
    index_existed,
    service_existed,
    service_was_active,
) = sys.argv[1:]

payload = {
    "version": 1,
    "kind": "protocol-config",
    "txn_dir": txn_dir,
    "state_dir": state_dir,
    "config_target": config_target,
    "meta_target": meta_target,
    "index_target": index_target,
    "service_target": service_target,
    "operation": operation,
    "tag": tag,
    "init": init,
    "config_backup": "backup/config.json",
    "meta_backup": "backup/meta.json",
    "index_backup": "backup/subscriptions.json",
    "service_backup": "backup/service",
    "config_existed": boolean(config_existed),
    "meta_existed": boolean(meta_existed),
    "index_existed": boolean(index_existed),
    "service_existed": boolean(service_existed),
    "service_was_active": boolean(service_was_active),
}
Path(manifest_file).write_text(
    json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_protocol_txn_manifest_is_valid() {
  local txn_dir="$1" manifest_file init expected_service_target
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_protocol_txn_manifest_path "$txn_dir")"
  if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
    subflow_fail "缺少可信协议恢复清单"
    return 1
  fi
  init="$(subflow_protocol_txn_manifest_field "$txn_dir" init)" || return 1
  expected_service_target="$(subflow_service_target "$init")" || return 1

  python3 - "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_CONFIG_PATH" "$SUBFLOW_META_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" \
    "$expected_service_target" <<'PY'
import json
import sys
from pathlib import Path

manifest_file, txn_dir, state_dir, config_target, meta_target, index_target, service_target = sys.argv[1:]
try:
    payload = json.loads(Path(manifest_file).read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)

expected = {
    "version": 1,
    "kind": "protocol-config",
    "txn_dir": txn_dir,
    "state_dir": state_dir,
    "config_target": config_target,
    "meta_target": meta_target,
    "index_target": index_target,
    "service_target": service_target,
    "config_backup": "backup/config.json",
    "meta_backup": "backup/meta.json",
    "index_backup": "backup/subscriptions.json",
    "service_backup": "backup/service",
}
if any(payload.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
if payload.get("init") not in {"systemd", "openrc"}:
    raise SystemExit(1)
if payload.get("operation") not in {"add", "update", "delete"}:
    raise SystemExit(1)
if not isinstance(payload.get("tag"), str):
    raise SystemExit(1)
for field in ("config_existed", "meta_existed", "index_existed", "service_existed", "service_was_active"):
    if type(payload.get(field)) is not bool:
        raise SystemExit(1)
PY
  if [[ "$?" -ne 0 ]]; then
    subflow_fail "非法协议恢复清单: ${manifest_file}"
    return 1
  fi
}

subflow_protocol_txn_manifest_field() {
  local txn_dir="$1" field="$2" manifest_file
  case "$field" in
    init|service_target|config_existed|meta_existed|index_existed|service_existed|service_was_active) ;;
    *) return 1 ;;
  esac
  manifest_file="$(subflow_protocol_txn_manifest_path "$txn_dir")"
  python3 - "$manifest_file" "$field" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = payload[sys.argv[2]]
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, str):
    print(value)
else:
    raise SystemExit(1)
PY
}

subflow_protocol_txn_restore_file() {
  local existed="$1" backup_file="$2" target_file="$3" mode="$4"
  if [[ "$existed" == "true" ]]; then
    if [[ ! -f "$backup_file" || -L "$backup_file" ]]; then
      subflow_fail "缺少可信协议事务备份: ${backup_file}"
      return 1
    fi
    subflow_file_write_atomic "$target_file" "$backup_file" "$mode"
  else
    rm -f "$target_file"
  fi
}

subflow_protocol_restore_from_manifest() {
  local txn_dir="$1" backup_dir
  local init service_target config_existed meta_existed index_existed service_existed service_was_active service_mode
  if ! subflow_protocol_txn_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  backup_dir="$txn_dir/backup"
  init="$(subflow_protocol_txn_manifest_field "$txn_dir" init)" || return 1
  service_target="$(subflow_protocol_txn_manifest_field "$txn_dir" service_target)" || return 1
  config_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" config_existed)" || return 1
  meta_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" meta_existed)" || return 1
  index_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" index_existed)" || return 1
  service_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" service_existed)" || return 1
  service_was_active="$(subflow_protocol_txn_manifest_field "$txn_dir" service_was_active)" || return 1
  if [[ "$init" == "systemd" ]]; then service_mode=644; else service_mode=755; fi

  for entry in \
    "$config_existed:$backup_dir/config.json" \
    "$meta_existed:$backup_dir/meta.json" \
    "$index_existed:$backup_dir/subscriptions.json" \
    "$service_existed:$backup_dir/service"; do
    if [[ "${entry%%:*}" == "true" ]]; then
      local backup_path="${entry#*:}"
      if [[ ! -f "$backup_path" || -L "$backup_path" ]]; then
        subflow_fail "缺少可信协议事务备份: ${backup_path}"
        return 1
      fi
    fi
  done

  subflow_protocol_txn_restore_file "$config_existed" "$backup_dir/config.json" "$SUBFLOW_CONFIG_PATH" 600 || return 1
  subflow_protocol_txn_restore_file "$meta_existed" "$backup_dir/meta.json" "$SUBFLOW_META_PATH" 600 || return 1
  subflow_protocol_txn_restore_file "$index_existed" "$backup_dir/subscriptions.json" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" 600 || return 1
  subflow_protocol_txn_restore_file "$service_existed" "$backup_dir/service" "$service_target" "$service_mode" || return 1
  subflow_service_reload_after_restore "$init" "$service_was_active" "$service_existed"
}

subflow_protocol_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_protocol_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧配置"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_protocol_candidate_is_managed() {
  local txn_dir="$1" candidate="$2" txn_real candidate_parent
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  txn_real="$(cd "$txn_dir" && pwd -P)" || return 1
  candidate_parent="$(cd "$(dirname "$candidate")" && pwd -P)" || return 1
  [[ "$candidate_parent" == "$txn_real" ]]
}

subflow_protocol_backup_if_present() {
  local existed="$1" source_file="$2" backup_file="$3"
  if [[ "$existed" == "true" ]]; then
    cp "$source_file" "$backup_file"
  fi
}

subflow_protocol_apply_candidates() {
  local txn_dir="$1" operation="$2" tag="$3"
  local candidate_config="$4" candidate_meta="$5" candidate_index="$6"
  local init service_target backup_dir source operation_label
  local config_existed=false meta_existed=false index_existed=false service_existed=false service_was_active=false

  for source in "$candidate_config" "$candidate_meta" "$candidate_index"; do
    if ! subflow_protocol_candidate_is_managed "$txn_dir" "$source"; then
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      subflow_fail "候选协议文件不在受管事务目录"
      return 1
    fi
  done
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
  backup_dir="$txn_dir/backup"
  mkdir -p "$backup_dir" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }

  [[ -f "$SUBFLOW_CONFIG_PATH" ]] && config_existed=true
  [[ -f "$SUBFLOW_META_PATH" ]] && meta_existed=true
  [[ -f "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]] && index_existed=true
  [[ -f "$service_target" ]] && service_existed=true
  if subflow_service_is_active "$init"; then service_was_active=true; fi

  if ! subflow_protocol_backup_if_present "$config_existed" "$SUBFLOW_CONFIG_PATH" "$backup_dir/config.json" \
    || ! subflow_protocol_backup_if_present "$meta_existed" "$SUBFLOW_META_PATH" "$backup_dir/meta.json" \
    || ! subflow_protocol_backup_if_present "$index_existed" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$backup_dir/subscriptions.json" \
    || ! subflow_protocol_backup_if_present "$service_existed" "$service_target" "$backup_dir/service"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  chmod 600 "$backup_dir"/* 2>/dev/null || true

  if ! subflow_protocol_txn_write_manifest "$txn_dir" "$operation" "$tag" "$init" \
    "$config_existed" "$meta_existed" "$index_existed" "$service_existed" "$service_was_active" \
    || ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  if ! subflow_json_write_atomic "$SUBFLOW_CONFIG_PATH" "$candidate_config" \
    || ! subflow_json_write_atomic "$SUBFLOW_META_PATH" "$candidate_meta" \
    || ! subflow_json_write_atomic "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$candidate_index"; then
    subflow_protocol_rollback "$txn_dir" "协议文件写入失败"
    return 1
  fi
  if ! subflow_service_write_definition "$init" || ! subflow_service_enable_and_restart "$init"; then
    subflow_protocol_rollback "$txn_dir" "sing-box 服务应用失败"
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  case "$operation" in
    add) operation_label="新增" ;;
    update) operation_label="更新" ;;
    delete) operation_label="删除" ;;
  esac
  ok "协议 ${tag} 已${operation_label}"
}