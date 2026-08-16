subflow_key_paths() {
  printf '%s\n' "$SUBFLOW_CONFIG_PATH"
  printf '%s\n' "$SUBFLOW_USERS_PATH"
  printf '%s\n' "$SUBFLOW_META_PATH"
  printf '%s\n' "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"
}

subflow_state_paths() {
  printf '%s\n' "$SUBFLOW_STATE_DIR"
  printf '%s\n' "$SUBFLOW_SECRETS_DIR"
  printf '%s\n' "$SUBFLOW_LOCK_PATH"
}

subflow_service_paths() {
  subflow_service_unit_path
}
