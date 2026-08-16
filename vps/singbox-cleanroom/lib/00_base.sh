umask 077

SUBFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${SUBFLOW_CONFIG_PATH:=/etc/sing-box/config.json}"
: "${SUBFLOW_USERS_PATH:=/etc/sing-box-manager/users.json}"
: "${SUBFLOW_META_PATH:=/etc/sing-box-manager/meta.json}"
: "${SUBFLOW_SUBSCRIPTION_INDEX_PATH:=/etc/sing-box-manager/subscriptions.json}"
: "${SUBFLOW_STATE_DIR:=/etc/sing-box-manager}"
: "${SUBFLOW_SECRETS_DIR:=/etc/sing-box-manager/secrets}"
: "${SUBFLOW_LOCK_PATH:=/var/lock/subflow-singbox.lock}"
: "${SUBFLOW_SINGBOX_BIN:=/usr/local/bin/sing-box}"
: "${SUBFLOW_SERVICE_NAME:=sing-box}"
: "${SUBFLOW_VERSION_STAMP:=${SUBFLOW_STATE_DIR}/.installed-release}"
: "${SUBFLOW_BINARY_STORE_DIR:=/var/lib/subflow-singbox/versions}"
: "${SUBFLOW_MANAGER_TARGET:=/root/sb.sh}"
: "${SUBFLOW_SHORTCUT_PATH:=/usr/local/bin/s}"
: "${SUBFLOW_SYSTEMD_UNIT_PATH:=/etc/systemd/system/${SUBFLOW_SERVICE_NAME}.service}"
: "${SUBFLOW_OPENRC_SERVICE_PATH:=/etc/init.d/${SUBFLOW_SERVICE_NAME}}"
: "${SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH:=${SUBFLOW_SECRETS_DIR}/cloudflare-acme.json}"
: "${SUBFLOW_ACME_DATA_DIR:=${SUBFLOW_SECRETS_DIR}/acme}"

subflow_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

subflow_has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

subflow_require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! subflow_has_cmd "$cmd"; then
      subflow_fail "缺少必要命令: ${cmd}"
      return 1
    fi
  done
}

subflow_is_valid_username() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

subflow_owner_from_name() {
  local name="$1"
  if [[ "$name" == *"@"* ]]; then
    printf '%s\n' "${name#*@}"
  else
    printf '%s\n' "admin"
  fi
}

subflow_username_from_name() {
  subflow_owner_from_name "$1"
}

subflow_json_is_object() {
  local file="$1"
  subflow_has_cmd jq || return 1
  jq -e 'type == "object"' "$file" >/dev/null 2>&1
}

subflow_json_is_array() {
  local file="$1"
  subflow_has_cmd jq || return 1
  jq -e 'type == "array"' "$file" >/dev/null 2>&1
}

subflow_json_validate() {
  local file="$1"
  if ! subflow_has_cmd jq; then
    subflow_fail "缺少必要命令: jq"
    return 1
  fi
  jq -e . "$file" >/dev/null
}

subflow_file_write_atomic() {
  local target="$1"
  local content_file="$2"
  local mode="$3"
  local target_dir tmp_file
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir" || return 1
  tmp_file="$(mktemp "${target_dir}/.${RANDOM:-0}.XXXXXX")" || return 1
  if ! cp "$content_file" "$tmp_file" || ! chmod "$mode" "$tmp_file" || ! mv -f "$tmp_file" "$target"; then
    rm -f "$tmp_file"
    return 1
  fi
}

subflow_json_write_atomic() {
  subflow_file_write_atomic "$1" "$2" 600
}

subflow_service_unit_path() {
  case "${SUBFLOW_INIT:-$(subflow_detect_init)}" in
    systemd)
      printf '%s\n' "$SUBFLOW_SYSTEMD_UNIT_PATH"
      ;;
    openrc)
      printf '%s\n' "$SUBFLOW_OPENRC_SERVICE_PATH"
      ;;
  esac
}

subflow_binary_exists() {
  [[ -x "$SUBFLOW_SINGBOX_BIN" ]]
}

subflow_key_file_state() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf '存在'
  else
    printf '缺失'
  fi
}

subflow_json_dir_ready() {
  mkdir -p "$SUBFLOW_STATE_DIR" "$SUBFLOW_SECRETS_DIR"
}
