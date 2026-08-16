#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
UI_FILE="${SCRIPT_DIR}/../shared/ui.sh"
RELEASES_FILE="${SCRIPT_DIR}/../../configs/sing-box-releases.json"
REALITY_MUTATOR_FILE="${SCRIPT_DIR}/python/reality_mutator.py"
SHADOWSOCKS_MUTATOR_FILE="${SCRIPT_DIR}/python/shadowsocks_mutator.py"
USER_CONFIG_MUTATOR_FILE="${SCRIPT_DIR}/python/user_config_mutator.py"
USER_TRANSACTION_MANIFEST_FILE="${SCRIPT_DIR}/python/user_transaction_manifest.py"
ACME_SECRET_FILE="${SCRIPT_DIR}/python/acme_secret.py"
TLS_PROTOCOL_MUTATOR_FILE="${SCRIPT_DIR}/python/tls_protocol_mutator.py"
OUT_FILE="${SCRIPT_DIR}/sb.sh"

umask 077

modules=(
  "${LIB_DIR}/00_base.sh"
  "${LIB_DIR}/05_releases.sh"
  "${LIB_DIR}/10_platform.sh"
  "${LIB_DIR}/20_paths.sh"
  "${LIB_DIR}/30_lock.sh"
  "${LIB_DIR}/40_json.sh"
  "${LIB_DIR}/50_status.sh"
  "${LIB_DIR}/60_doctor.sh"
  "${LIB_DIR}/70_check.sh"
  "${LIB_DIR}/75_service.sh"
  "${LIB_DIR}/80_acme.sh"
  "${LIB_DIR}/80_install.sh"
  "${LIB_DIR}/81_protocols.sh"
  "${LIB_DIR}/82_protocol_transaction.sh"
  "${LIB_DIR}/83_reality.sh"
  "${LIB_DIR}/83_shadowsocks.sh"
  "${LIB_DIR}/83_tls_protocols.sh"
  "${LIB_DIR}/84_protocol_dispatch.sh"
  "${LIB_DIR}/84_rebuild.sh"
  "${LIB_DIR}/85_users.sh"
  "${LIB_DIR}/86_recover.sh"
  "${LIB_DIR}/90_cli.sh"
)
last_module="${modules[$((${#modules[@]} - 1))]}"

for module in "${modules[@]}"; do
  [[ -f "$module" ]] || { printf 'missing module: %s\n' "$module" >&2; exit 1; }
done
[[ -f "$UI_FILE" ]] || { printf 'missing shared ui: %s\n' "$UI_FILE" >&2; exit 1; }
[[ -f "$RELEASES_FILE" ]] || { printf 'missing release manifest: %s\n' "$RELEASES_FILE" >&2; exit 1; }
[[ -f "$REALITY_MUTATOR_FILE" ]] || { printf 'missing Reality mutator: %s\n' "$REALITY_MUTATOR_FILE" >&2; exit 1; }
[[ -f "$SHADOWSOCKS_MUTATOR_FILE" ]] || { printf 'missing Shadowsocks mutator: %s\n' "$SHADOWSOCKS_MUTATOR_FILE" >&2; exit 1; }
[[ -f "$USER_CONFIG_MUTATOR_FILE" ]] || { printf 'missing user config mutator: %s\n' "$USER_CONFIG_MUTATOR_FILE" >&2; exit 1; }
[[ -f "$USER_TRANSACTION_MANIFEST_FILE" ]] || { printf 'missing user transaction manifest tool: %s\n' "$USER_TRANSACTION_MANIFEST_FILE" >&2; exit 1; }
[[ -f "$ACME_SECRET_FILE" ]] || { printf 'missing ACME secret tool: %s\n' "$ACME_SECRET_FILE" >&2; exit 1; }
[[ -f "$TLS_PROTOCOL_MUTATOR_FILE" ]] || { printf 'missing TLS protocol mutator: %s\n' "$TLS_PROTOCOL_MUTATOR_FILE" >&2; exit 1; }

tmp_file="$(mktemp "${SCRIPT_DIR}/.sb.sh.XXXXXX")"
{
  printf '#!/usr/bin/env bash\n'
  printf '# shellcheck shell=bash\n'
  printf 'set -Eeuo pipefail\n'
  printf '\n'
  sed '1d' "$UI_FILE"
  printf '\n'
  printf '%s\n' 'subflow_release_manifest() {'
  printf '%s\n' '  if [[ -n "${SUBFLOW_RELEASE_MANIFEST_PATH:-}" ]]; then'
  printf '%s\n' '    cat -- "$SUBFLOW_RELEASE_MANIFEST_PATH"'
  printf '%s\n' '    return'
  printf '%s\n' '  fi'
  printf '%s\n' "  cat <<'SUBFLOW_RELEASE_MANIFEST_JSON'"
  cat "$RELEASES_FILE"
  printf '\n%s\n' 'SUBFLOW_RELEASE_MANIFEST_JSON'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' 'subflow_reality_mutator_source() {'
  printf '%s\n' "  cat <<'SUBFLOW_REALITY_MUTATOR_PY'"
  cat "$REALITY_MUTATOR_FILE"
  printf '\n%s\n' 'SUBFLOW_REALITY_MUTATOR_PY'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' 'subflow_shadowsocks_mutator_source() {'
  printf '%s\n' "  cat <<'SUBFLOW_SHADOWSOCKS_MUTATOR_PY'"
  cat "$SHADOWSOCKS_MUTATOR_FILE"
  printf '\n%s\n' 'SUBFLOW_SHADOWSOCKS_MUTATOR_PY'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' 'subflow_user_config_mutator_source() {'
  printf '%s\n' "  cat <<'SUBFLOW_USER_CONFIG_MUTATOR_PY'"
  cat "$USER_CONFIG_MUTATOR_FILE"
  printf '\n%s\n' 'SUBFLOW_USER_CONFIG_MUTATOR_PY'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' 'subflow_user_transaction_manifest_source() {'
  printf '%s\n' "  cat <<'SUBFLOW_USER_TRANSACTION_MANIFEST_PY'"
  cat "$USER_TRANSACTION_MANIFEST_FILE"
  printf '\n%s\n' 'SUBFLOW_USER_TRANSACTION_MANIFEST_PY'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' 'subflow_acme_secret_source() {'
  printf '%s\n' "  cat <<'SUBFLOW_ACME_SECRET_PY'"
  cat "$ACME_SECRET_FILE"
  printf '\n%s\n' 'SUBFLOW_ACME_SECRET_PY'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' 'subflow_tls_protocol_mutator_source() {'
  printf '%s\n' "  cat <<'SUBFLOW_TLS_PROTOCOL_MUTATOR_PY'"
  cat "$TLS_PROTOCOL_MUTATOR_FILE"
  printf '\n%s\n' 'SUBFLOW_TLS_PROTOCOL_MUTATOR_PY'
  printf '%s\n' '}'
  printf '\n'
  for module in "${modules[@]}"; do
    printf '# --- %s ---\n' "$(basename "$module")"
    cat "$module"
    if [[ "$module" != "$last_module" ]]; then
      printf '\n'
    fi
  done
} > "$tmp_file"

chmod 700 "$tmp_file"
mv -f "$tmp_file" "$OUT_FILE"
printf '%s\n' "$OUT_FILE"