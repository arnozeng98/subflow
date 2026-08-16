subflow_rebuild_jq_program() {
  cat <<'JQ'
def owner_from_name:
  if type == "string" and test("@"); then split("@")[ -1 ] else "admin" end;

def user_name_from_name:
  if type == "string" and test("@"); then split("@")[ -1 ] else "admin" end;

def safe_user_entry:
  {
    name: .name,
    username: (.name | user_name_from_name),
    uuid: (.uuid // empty),
    password: (.password // empty),
    flow: (.flow // empty)
  }
  | with_entries(select(.value != null and .value != ""));

def selected_inbound_users($username):
  [ .users[]? | select((.name | owner_from_name) == $username) | safe_user_entry ];

def selected_transport:
  if .transport? == null then {}
  else {transport: {type: .transport.type, path: .transport.path} | with_entries(select(.value != null))}
  end;

def selected_tls:
  if .tls? == null then {}
  else
    {tls: ({server_name: .tls.server_name}
      + (if .tls.reality? == null then {} else {reality: {enabled: .tls.reality.enabled, short_id: (.tls.reality.short_id // [])}} end))
      | with_entries(select(.value != null))}
  end;

def selected_inbound($username):
  . as $inbound
  | (selected_inbound_users($username)) as $users
  | if ($users | length) == 0 then empty
    else
      {
        type: $inbound.type,
        tag: $inbound.tag,
        listen_port: $inbound.listen_port,
        users: $users
      }
      + (if $inbound.type == "shadowsocks" and $inbound.method? != null then {method: $inbound.method} else {} end)
      + (if $inbound.type == "shadowsocks" and $inbound.password? != null then {password: $inbound.password} else {} end)
      + selected_transport
      + selected_tls
    end;

def selected_meta($username):
  reduce ($config.inbounds[]? | select(.tag? != null)) as $inbound ({};
    if ($inbound.type == "vless")
      and (($inbound.tls.reality.enabled // false) == true)
      and ([ $inbound.users[]? | select((.name | owner_from_name) == $username) ] | length > 0)
      and ($meta[$inbound.tag].public_key? != null)
    then . + {($inbound.tag): {public_key: $meta[$inbound.tag].public_key}}
    else . end);

{
  schema_version: 1,
  users: (
    ($users.users // {})
    | to_entries
    | sort_by(.key)
    | reduce .[] as $entry ({},
        . + {
          ($entry.key): {
            usage: (
              $entry.value
              | {
                  enabled: (.enabled // true),
                  disabled_reason: (.disabled_reason // null),
                  quota_gb: (.quota_gb // 0),
                  used_up_bytes: (.used_up_bytes // 0),
                  used_down_bytes: (.used_down_bytes // 0),
                  manual_added_bytes: (.manual_added_bytes // 0),
                  last_live_up_bytes: (.last_live_up_bytes // 0),
                  last_live_down_bytes: (.last_live_down_bytes // 0),
                  last_reset_period: (.last_reset_period // ""),
                  reset_day: (.reset_day // 0),
                  expire_at: (.expire_at // "0"),
                  allow_all_nodes: (.allow_all_nodes // true),
                  nodes: (.nodes // [])
                }
            ),
            inbounds: [ $config.inbounds[]? | selected_inbound($entry.key) ],
            meta: selected_meta($entry.key)
          }
        }
      )
  )
}
JQ
}

subflow_rebuild_generate_subscription_index_from_files() {
  local config_file="$1"
  local users_file="$2"
  local meta_file="$3"
  local candidate_file="$4"
  local jq_program

  subflow_require_cmd jq || return 1
  subflow_json_require_file "$config_file" || return 1
  subflow_json_require_file "$users_file" || return 1
  subflow_json_require_file "$meta_file" || return 1
  subflow_json_require_object "$config_file" || return 1
  subflow_json_require_schema_v1 "$users_file" || return 1
  subflow_json_require_object "$meta_file" || return 1
  jq_program="$(subflow_rebuild_jq_program)" || return 1

  if ! jq -n \
    --argfile config "$config_file" \
    --argfile users "$users_file" \
    --argfile meta "$meta_file" \
    "$jq_program" >"$candidate_file"; then
    return 1
  fi

  subflow_json_validate "$candidate_file" || return 1
  subflow_check_subscription_index_file "$candidate_file" || return 1
}

subflow_rebuild_generate_subscription_index_for_users_file() {
  local users_file="$1"
  local candidate_file="$2"

  subflow_rebuild_generate_subscription_index_from_files \
    "$SUBFLOW_CONFIG_PATH" \
    "$users_file" \
    "$SUBFLOW_META_PATH" \
    "$candidate_file"
}

cmd_rebuild() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi

  local txn_dir candidate_file output_file
  if ! txn_dir="$(subflow_txn_dir_create)"; then
    subflow_lock_release
    return 1
  fi
  candidate_file="${txn_dir}/subscriptions.json"

  if ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  if ! subflow_rebuild_generate_subscription_index_from_files \
    "$SUBFLOW_CONFIG_PATH" \
    "$SUBFLOW_USERS_PATH" \
    "$SUBFLOW_META_PATH" \
    "$candidate_file"; then
    subflow_txn_abort "$txn_dir"
    subflow_lock_release
    return 1
  fi

  if subflow_binary_exists && ! "$SUBFLOW_SINGBOX_BIN" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null 2>&1; then
    subflow_txn_abort "$txn_dir"
    subflow_lock_release
    subflow_fail "sing-box check 失败，未写入订阅索引"
    return 1
  fi

  output_file="$SUBFLOW_SUBSCRIPTION_INDEX_PATH"
  if ! subflow_json_write_atomic "$output_file" "$candidate_file"; then
    subflow_txn_abort "$txn_dir"
    subflow_lock_release
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "订阅索引已重建"
}
