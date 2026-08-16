subflow_require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    subflow_fail "安装或更新 sing-box 需要 root 权限"
    return 1
  fi
}

subflow_binary_version() {
  local binary="$1" output first_line
  output="$("$binary" version 2>&1)" || return 1
  first_line="${output%%$'\n'*}"
  if [[ ! "$first_line" =~ ^sing-box[[:space:]]+(version[[:space:]]+)?v?([0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?) ]]; then
    return 1
  fi
  printf '%s\n' "${BASH_REMATCH[2]}"
}

subflow_install_verify_candidate() {
  local candidate="$1" version="$2" expected_sha256="$3"
  local actual_version version_output tag

  if ! printf '%s  %s\n' "$expected_sha256" "$candidate" | sha256sum -c - >/dev/null 2>&1; then
    subflow_fail "sing-box 下载文件 SHA256 不匹配"
    return 1
  fi
  chmod 755 "$candidate" || return 1
  actual_version="$(subflow_binary_version "$candidate")" || {
    subflow_fail "无法读取候选 sing-box 版本"
    return 1
  }
  if [[ "$actual_version" != "$version" ]]; then
    subflow_fail "候选版本不匹配: 期望 ${version}，实际 ${actual_version}"
    return 1
  fi
  version_output="$("$candidate" version 2>&1)" || return 1
  for tag in with_v2ray_api with_wireguard with_acme; do
    if [[ "$version_output" != *"$tag"* ]]; then
      subflow_fail "候选 sing-box 缺少构建标签: ${tag}"
      return 1
    fi
  done
  if [[ -f "$SUBFLOW_CONFIG_PATH" ]] && ! "$candidate" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null 2>&1; then
    subflow_fail "候选 sing-box 无法通过现有配置检查"
    return 1
  fi
}

subflow_install_manifest_path() {
  printf '%s\n' "$1/install.manifest.json"
}

subflow_install_write_manifest() {
  local txn_dir="$1" init="$2" binary_existed="$3" stamp_existed="$4"
  local service_changed="$5" service_existed="$6" service_was_active="$7"
  local manifest_file service_target
  manifest_file="$(subflow_install_manifest_path "$txn_dir")"
  service_target="$(subflow_service_target "$init")" || return 1

  if ! jq -n \
    --arg txn_dir "$txn_dir" \
    --arg state_dir "$SUBFLOW_STATE_DIR" \
    --arg binary_target "$SUBFLOW_SINGBOX_BIN" \
    --arg stamp_target "$SUBFLOW_VERSION_STAMP" \
    --arg service_target "$service_target" \
    --arg init "$init" \
    --argjson binary_existed "$binary_existed" \
    --argjson stamp_existed "$stamp_existed" \
    --argjson service_changed "$service_changed" \
    --argjson service_existed "$service_existed" \
    --argjson service_was_active "$service_was_active" \
    '{
      version: 1,
      kind: "sing-box-install",
      txn_dir: $txn_dir,
      state_dir: $state_dir,
      binary_target: $binary_target,
      stamp_target: $stamp_target,
      service_target: $service_target,
      init: $init,
      binary_backup: "backup/sing-box",
      stamp_backup: "backup/installed-release",
      service_backup: "backup/service",
      binary_existed: $binary_existed,
      stamp_existed: $stamp_existed,
      service_changed: $service_changed,
      service_existed: $service_existed,
      service_was_active: $service_was_active
    }' >"$manifest_file"; then
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_install_manifest_is_valid() {
  local txn_dir="$1" manifest_file init service_target expected_service_target
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_install_manifest_path "$txn_dir")"
  subflow_json_require_object "$manifest_file" || return 1
  init="$(jq -er '.init' "$manifest_file")" || return 1
  service_target="$(jq -er '.service_target' "$manifest_file")" || return 1
  expected_service_target="$(subflow_service_target "$init")" || return 1
  if [[ "$service_target" != "$expected_service_target" ]]; then
    subflow_fail "安装恢复清单中的服务路径不合法"
    return 1
  fi
  if ! jq -e \
    --arg txn_dir "$txn_dir" \
    --arg state_dir "$SUBFLOW_STATE_DIR" \
    --arg binary_target "$SUBFLOW_SINGBOX_BIN" \
    --arg stamp_target "$SUBFLOW_VERSION_STAMP" \
    'type == "object"
     and .version == 1
     and .kind == "sing-box-install"
     and .txn_dir == $txn_dir
     and .state_dir == $state_dir
     and .binary_target == $binary_target
     and .stamp_target == $stamp_target
     and (.init == "systemd" or .init == "openrc")
     and .binary_backup == "backup/sing-box"
     and .stamp_backup == "backup/installed-release"
     and .service_backup == "backup/service"
     and (.binary_existed | type == "boolean")
     and (.stamp_existed | type == "boolean")
     and (.service_changed | type == "boolean")
     and (.service_existed | type == "boolean")
     and (.service_was_active | type == "boolean")' "$manifest_file" >/dev/null; then
    subflow_fail "非法安装恢复清单: ${manifest_file}"
    return 1
  fi
}

subflow_install_restore_file() {
  local existed="$1" backup_file="$2" target_file="$3" mode="$4"
  if [[ "$existed" == "true" ]]; then
    if [[ ! -f "$backup_file" || -L "$backup_file" ]]; then
      subflow_fail "缺少可信安装备份: ${backup_file}"
      return 1
    fi
    subflow_file_write_atomic "$target_file" "$backup_file" "$mode"
  else
    rm -f "$target_file"
  fi
}

subflow_install_restore_from_manifest() {
  local txn_dir="$1" manifest_file backup_dir
  local init binary_existed stamp_existed service_changed service_existed service_was_active service_target
  if ! subflow_install_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_install_manifest_path "$txn_dir")"
  backup_dir="$txn_dir/backup"
  init="$(jq -er '.init' "$manifest_file")" || return 1
  binary_existed="$(jq -er '.binary_existed' "$manifest_file")" || return 1
  stamp_existed="$(jq -er '.stamp_existed' "$manifest_file")" || return 1
  service_changed="$(jq -er '.service_changed' "$manifest_file")" || return 1
  service_existed="$(jq -er '.service_existed' "$manifest_file")" || return 1
  service_was_active="$(jq -er '.service_was_active' "$manifest_file")" || return 1
  service_target="$(jq -er '.service_target' "$manifest_file")" || return 1

  if [[ "$binary_existed" == "true" && ( ! -f "$backup_dir/sing-box" || -L "$backup_dir/sing-box" ) ]]; then
    subflow_fail "缺少可信安装备份: ${backup_dir}/sing-box"
    return 1
  fi
  if [[ "$stamp_existed" == "true" && ( ! -f "$backup_dir/installed-release" || -L "$backup_dir/installed-release" ) ]]; then
    subflow_fail "缺少可信安装备份: ${backup_dir}/installed-release"
    return 1
  fi
  if [[ "$service_changed" == "true" && "$service_existed" == "true" && ( ! -f "$backup_dir/service" || -L "$backup_dir/service" ) ]]; then
    subflow_fail "缺少可信安装备份: ${backup_dir}/service"
    return 1
  fi

  subflow_install_restore_file "$binary_existed" "$backup_dir/sing-box" "$SUBFLOW_SINGBOX_BIN" 755 || return 1
  subflow_install_restore_file "$stamp_existed" "$backup_dir/installed-release" "$SUBFLOW_VERSION_STAMP" 600 || return 1
  if [[ "$service_changed" == "true" ]]; then
    subflow_install_restore_file "$service_existed" "$backup_dir/service" "$service_target" "$([[ "$init" == "systemd" ]] && printf 644 || printf 755)" || return 1
    subflow_service_reload_after_restore "$init" "$service_was_active" "$service_existed" || return 1
  fi
}

subflow_install_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_install_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧版本"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_install_manager_entrypoint() {
  local source_file="${BASH_SOURCE[0]}" shortcut_file
  if [[ ! -r "$source_file" || "$SUBFLOW_MANAGER_TARGET" == *'"'* || "$SUBFLOW_MANAGER_TARGET" == *$'\n'* ]]; then
    subflow_fail "无法安装管理器入口"
    return 1
  fi
  subflow_file_write_atomic "$SUBFLOW_MANAGER_TARGET" "$source_file" 700 || return 1
  shortcut_file="$(mktemp)" || return 1
  printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$SUBFLOW_MANAGER_TARGET" >"$shortcut_file"
  if ! subflow_file_write_atomic "$SUBFLOW_SHORTCUT_PATH" "$shortcut_file" 755; then
    rm -f "$shortcut_file"
    return 1
  fi
  rm -f "$shortcut_file"
}

subflow_install_archive_binary() {
  local binary="$1" version="$2" target
  target="${SUBFLOW_BINARY_STORE_DIR}/${version}/sing-box"
  subflow_file_write_atomic "$target" "$binary" 755
}

subflow_install_version() {
  local requested_version="$1" version arch init expected_sha256 download_url
  local txn_dir candidate_file backup_dir service_target current_version stamp_candidate
  local binary_existed=false stamp_existed=false service_changed=false service_existed=false service_was_active=false

  subflow_require_root || return 1
  subflow_require_cmd curl jq sha256sum flock id uname mktemp cp chmod mv || return 1
  arch="$(subflow_detect_arch)" || return 1
  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || return 1
  fi
  subflow_service_target "$init" >/dev/null || return 1
  subflow_detect_pkg_manager >/dev/null || return 1
  if [[ -n "$requested_version" ]]; then
    version="$(subflow_release_normalize_version "$requested_version")" || return 1
  else
    version="$(subflow_release_latest)" || return 1
  fi
  expected_sha256="$(subflow_release_sha256 "$version" "$arch")" || return 1
  download_url="$(subflow_release_url "$version" "$arch")" || return 1

  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  mkdir -p "$SUBFLOW_STATE_DIR" "$SUBFLOW_BINARY_STORE_DIR" || {
    subflow_lock_release
    return 1
  }
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate_file="$txn_dir/sing-box"
  backup_dir="$txn_dir/backup"
  mkdir -p "$backup_dir" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }

  if ! curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$candidate_file" "$download_url"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "下载 sing-box 失败"
    return 1
  fi
  if ! subflow_install_verify_candidate "$candidate_file" "$version" "$expected_sha256"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  service_target="$(subflow_service_target "$init")" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  [[ -f "$SUBFLOW_SINGBOX_BIN" ]] && binary_existed=true
  [[ -f "$SUBFLOW_VERSION_STAMP" ]] && stamp_existed=true
  if [[ -f "$SUBFLOW_CONFIG_PATH" ]]; then
    service_changed=true
    [[ -f "$service_target" ]] && service_existed=true
    if subflow_service_is_active "$init"; then
      service_was_active=true
    fi
  fi

  if [[ "$binary_existed" == "true" ]]; then
    cp "$SUBFLOW_SINGBOX_BIN" "$backup_dir/sing-box" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
    chmod 600 "$backup_dir/sing-box" 2>/dev/null || true
  fi
  if [[ "$stamp_existed" == "true" ]]; then
    cp "$SUBFLOW_VERSION_STAMP" "$backup_dir/installed-release" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  if [[ "$service_existed" == "true" ]]; then
    cp "$service_target" "$backup_dir/service" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  subflow_install_write_manifest "$txn_dir" "$init" "$binary_existed" "$stamp_existed" \
    "$service_changed" "$service_existed" "$service_was_active" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  subflow_txn_begin "$txn_dir" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }

  if [[ "$binary_existed" == "true" ]]; then
    current_version="$(subflow_binary_version "$SUBFLOW_SINGBOX_BIN" 2>/dev/null || true)"
    if [[ -n "$current_version" ]] && ! subflow_install_archive_binary "$SUBFLOW_SINGBOX_BIN" "$current_version"; then
      subflow_install_rollback "$txn_dir" "无法保留旧版 sing-box"
      return 1
    fi
  fi
  if ! subflow_file_write_atomic "$SUBFLOW_SINGBOX_BIN" "$candidate_file" 755; then
    subflow_install_rollback "$txn_dir" "写入 sing-box 二进制失败"
    return 1
  fi
  if [[ "$service_changed" == "true" ]]; then
    if ! subflow_service_write_definition "$init" || ! subflow_service_enable_and_restart "$init"; then
      subflow_install_rollback "$txn_dir" "sing-box 服务启动失败"
      return 1
    fi
  else
    note "配置文件不存在，仅安装二进制和管理器入口"
  fi

  stamp_candidate="$txn_dir/installed-release"
  printf '%s\n' "$version" >"$stamp_candidate"
  if ! subflow_file_write_atomic "$SUBFLOW_VERSION_STAMP" "$stamp_candidate" 600 \
    || ! subflow_install_archive_binary "$candidate_file" "$version" \
    || ! subflow_install_manager_entrypoint; then
    subflow_install_rollback "$txn_dir" "安装配套文件失败"
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "sing-box ${version} 已安装"
}

cmd_install_dispatch() {
  local version="" option
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    case "$option" in
      --version)
        version="${2:-}"
        [[ -n "$version" ]] || { subflow_fail "--version 需要参数"; return 1; }
        shift 2
        ;;
      *)
        subflow_fail "未知 install 参数: ${option}"
        return 1
        ;;
    esac
  done
  subflow_install_version "$version"
}

cmd_update() {
  [[ "$#" -eq 0 ]] || { subflow_fail "update 不接受参数"; return 1; }
  subflow_install_version ""
}