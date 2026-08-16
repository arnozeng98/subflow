subflow_lock_acquire() {
  if ! subflow_has_cmd flock; then
    subflow_fail "缺少必要命令: flock"
    return 1
  fi
  if ! mkdir -p "$(dirname "$SUBFLOW_LOCK_PATH")"; then
    subflow_fail "无法创建锁目录"
    return 1
  fi
  if ! exec {SUBFLOW_LOCK_FD}>"$SUBFLOW_LOCK_PATH"; then
    subflow_fail "无法创建锁文件"
    return 1
  fi
  if ! flock -n "$SUBFLOW_LOCK_FD"; then
    subflow_lock_release
    subflow_fail "已有另一个实例持有全局锁"
    return 1
  fi
}

subflow_lock_release() {
  if [[ -n "${SUBFLOW_LOCK_FD:-}" ]]; then
    flock -u "$SUBFLOW_LOCK_FD" >/dev/null 2>&1 || true
    { exec {SUBFLOW_LOCK_FD}>&-; } 2>/dev/null || true
    unset SUBFLOW_LOCK_FD
  fi
}

subflow_txn_dir_create() {
  mkdir -p "$SUBFLOW_STATE_DIR"
  mktemp -d "${SUBFLOW_STATE_DIR}/.txn.XXXXXX"
}

subflow_txn_dir_is_managed() {
  local txn_dir="$1" state_dir parent_dir base_name
  [[ -d "$SUBFLOW_STATE_DIR" ]] || return 1
  [[ -d "$txn_dir" ]] || return 1
  [[ ! -L "$txn_dir" ]] || return 1
  state_dir="$(cd "$SUBFLOW_STATE_DIR" && pwd -P)" || return 1
  parent_dir="$(cd "$(dirname "$txn_dir")" && pwd -P)" || return 1
  base_name="$(basename "$txn_dir")"
  [[ "$parent_dir" == "$state_dir" && "$base_name" =~ ^\.txn\.[A-Za-z0-9]+$ ]]
}

subflow_txn_require_managed() {
  local txn_dir="$1"
  if ! subflow_txn_dir_is_managed "$txn_dir"; then
    subflow_fail "非法事务目录: ${txn_dir}"
    return 1
  fi
}

subflow_txn_begin() {
  local txn_dir="$1"
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  : >"${txn_dir}/recovery.pending"
}

subflow_txn_commit() {
  local txn_dir="$1"
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  rm -f "${txn_dir}/recovery.pending"
}

subflow_txn_abort() {
  local txn_dir="$1"
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  rm -rf "$txn_dir"
}

subflow_txn_has_pending() {
  local pending
  for pending in "${SUBFLOW_STATE_DIR}"/.txn.*/recovery.pending; do
    [[ -e "$pending" ]] && return 0
  done
  return 1
}

subflow_txn_cleanup_stale() {
  local txn_dir pending_found=0
  for txn_dir in "${SUBFLOW_STATE_DIR}"/.txn.*; do
    [[ -d "$txn_dir" ]] || continue
    if [[ -e "${txn_dir}/recovery.pending" ]]; then
      pending_found=1
      continue
    fi
    if ! subflow_txn_abort "$txn_dir"; then
      return 1
    fi
  done
  if (( pending_found != 0 )); then
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
  fi
}
