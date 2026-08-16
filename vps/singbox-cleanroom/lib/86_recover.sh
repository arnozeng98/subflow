subflow_txn_find_pending_dir() {
  local txn_dir pending_count=0 found_dir=""
  for txn_dir in "${SUBFLOW_STATE_DIR}"/.txn.*; do
    [[ -d "$txn_dir" ]] || continue
    if [[ -e "${txn_dir}/recovery.pending" ]]; then
      found_dir="$txn_dir"
      pending_count=$((pending_count + 1))
    fi
  done
  if (( pending_count == 0 )); then
    return 1
  fi
  if (( pending_count > 1 )); then
    subflow_fail "发现多个未完成事务"
    return 2
  fi
  printf '%s\n' "$found_dir"
}

cmd_recover() {
  local txn_dir find_status

  if ! subflow_lock_acquire; then
    return 1
  fi
  if txn_dir="$(subflow_txn_find_pending_dir)"; then
    :
  else
    find_status=$?
    subflow_lock_release
    if (( find_status == 1 )); then
      ok "没有待恢复事务"
      return 0
    fi
    return "$find_status"
  fi

  if ! subflow_require_cmd jq; then
    subflow_lock_release
    return 1
  fi

  if [[ -f "$(subflow_acme_rotation_manifest_path "$txn_dir")" ]]; then
    if ! subflow_require_cmd python3 || ! subflow_acme_rotation_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  elif [[ -f "$(subflow_install_manifest_path "$txn_dir")" ]]; then
    if ! subflow_install_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  elif [[ -f "$(subflow_protocol_txn_manifest_path "$txn_dir")" ]]; then
    if ! subflow_require_cmd python3 || ! subflow_protocol_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  elif [[ -f "$(subflow_users_txn_manifest_path "$txn_dir")" ]]; then
    if ! subflow_users_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  else
    subflow_lock_release
    subflow_fail "未识别的待恢复事务"
    return 1
  fi

  if ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "事务已恢复"
}
