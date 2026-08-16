subflow_json_require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    subflow_fail "缺少文件: ${file}"
    return 1
  fi
}

subflow_json_require_object() {
  local file="$1"
  if ! subflow_json_require_file "$file" || ! subflow_json_validate "$file"; then
    return 1
  fi
  if ! jq -e 'type == "object"' "$file" >/dev/null; then
    subflow_fail "JSON 不是对象: ${file}"
    return 1
  fi
}

subflow_json_require_array() {
  local file="$1"
  if ! subflow_json_require_file "$file" || ! subflow_json_validate "$file"; then
    return 1
  fi
  if ! jq -e 'type == "array"' "$file" >/dev/null; then
    subflow_fail "JSON 不是数组: ${file}"
    return 1
  fi
}

subflow_json_require_schema_v1() {
  local file="$1"
  if ! jq -e 'type == "object" and .schema_version == 1 and (.users | type == "object")' "$file" >/dev/null; then
    subflow_fail "schema_version 不兼容: ${file}"
    return 1
  fi
}

subflow_json_write_string() {
  local target="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp "$(dirname "$target")/.value.XXXXXX")"
  printf '%s\n' "$value" >"$tmp_file"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$target"
}
