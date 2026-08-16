subflow_doctor_version_has_tags() {
  local version_output="$1"
  local tag
  for tag in with_v2ray_api with_wireguard with_acme; do
    if [[ "$version_output" != *"$tag"* ]]; then
      subflow_fail "sing-box 版本输出缺少构建标签: ${tag}"
      return 1
    fi
  done
}

subflow_doctor_check_permissions() {
  local path expected mode
  for path in "$SUBFLOW_CONFIG_PATH" "$SUBFLOW_USERS_PATH" "$SUBFLOW_META_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"; do
    if [[ -e "$path" ]]; then
      expected="600"
      if [[ -d "$path" ]]; then
        expected="700"
      fi
      mode="$(stat -c '%a' "$path")"
      [[ "$mode" == "$expected" ]] || return 1
    fi
  done

  if [[ -d "$SUBFLOW_SECRETS_DIR" ]]; then
    mode="$(stat -c '%a' "$SUBFLOW_SECRETS_DIR")"
    [[ "$mode" == "700" ]] || return 1
  fi
}

cmd_doctor() {
  local failures=0
  local version_output config_ok index_ok

  if ! subflow_require_cmd jq openssl tar sha256sum flock python3; then
    failures=$((failures + 1))
  fi
  subflow_binary_exists || { err "sing-box 二进制缺失"; failures=$((failures + 1)); }
  [[ -d "$SUBFLOW_STATE_DIR" ]] || { err "状态目录缺失"; failures=$((failures + 1)); }
  [[ -d "$SUBFLOW_SECRETS_DIR" ]] || { err "密钥目录缺失"; failures=$((failures + 1)); }
  subflow_doctor_check_permissions || { err "目录或文件权限不符合要求"; failures=$((failures + 1)); }

  if subflow_binary_exists; then
    version_output="$("$SUBFLOW_SINGBOX_BIN" version 2>&1)" || { err "无法读取 sing-box 版本"; failures=$((failures + 1)); version_output=""; }
    if [[ -n "$version_output" ]]; then
      subflow_doctor_version_has_tags "$version_output" || failures=$((failures + 1))
    fi
  fi

  if [[ -f "$SUBFLOW_CONFIG_PATH" ]]; then
    subflow_json_require_object "$SUBFLOW_CONFIG_PATH" || failures=$((failures + 1))
    if subflow_binary_exists; then
      if ! "$SUBFLOW_SINGBOX_BIN" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null 2>&1; then
        err "sing-box check 失败"
        failures=$((failures + 1))
      fi
    fi
  else
    err "配置文件缺失"
    failures=$((failures + 1))
  fi

  if [[ -f "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]]; then
    if subflow_json_require_object "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" && subflow_json_require_schema_v1 "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"; then
      index_ok=1
    else
      err "订阅索引不通过 schema 检查"
      failures=$((failures + 1))
    fi
  else
    err "订阅索引缺失"
    failures=$((failures + 1))
  fi

  if (( failures == 0 )); then
    ok "doctor 通过"
    return 0
  fi

  err "doctor 失败: ${failures} 项检查未通过"
  return 1
}
