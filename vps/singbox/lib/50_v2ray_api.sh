#!/usr/bin/env bash
# ============================================================
# 模块: 50_v2ray_api.sh
# 职责: gRPC 流量统计查询、meta 存储、grpcurl 安装
# 依赖: 00_base.sh, 01_utils.sh
# ============================================================

# ---------- Proto 文件管理 ----------

ensure_v2ray_api_proto_files() {
  mkdir -p /etc/sing-box
  cat > "$V2RAY_PROTO_EXP" <<'EOF_V2E'
syntax = "proto3";
package experimental.v2rayapi;
message GetStatsRequest { string name = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message GetStatsResponse { Stat stat = 1; }
message QueryStatsRequest { string pattern = 1; bool reset = 2; repeated string patterns = 3; bool regexp = 4; }
message QueryStatsResponse { repeated Stat stat = 1; }
message SysStatsRequest {}
message SysStatsResponse {
  uint32 NumGoroutine = 1; uint32 NumGC = 2; uint64 Alloc = 3; uint64 TotalAlloc = 4;
  uint64 Sys = 5; uint64 Mallocs = 6; uint64 Frees = 7; uint64 LiveObjects = 8; uint64 PauseTotalNs = 9; uint32 Uptime = 10;
}
service StatsService {
  rpc GetStats (GetStatsRequest) returns (GetStatsResponse);
  rpc QueryStats (QueryStatsRequest) returns (QueryStatsResponse);
  rpc GetSysStats (SysStatsRequest) returns (SysStatsResponse);
}
EOF_V2E

  cat > "$V2RAY_PROTO_V2RAY" <<'EOF_V2V'
syntax = "proto3";
package v2ray.core.app.stats.command;
message GetStatsRequest { string name = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message GetStatsResponse { Stat stat = 1; }
message QueryStatsRequest { string pattern = 1; bool reset = 2; repeated string patterns = 3; bool regexp = 4; }
message QueryStatsResponse { repeated Stat stat = 1; }
message SysStatsRequest {}
message SysStatsResponse {
  uint32 NumGoroutine = 1; uint32 NumGC = 2; uint64 Alloc = 3; uint64 TotalAlloc = 4;
  uint64 Sys = 5; uint64 Mallocs = 6; uint64 Frees = 7; uint64 LiveObjects = 8; uint64 PauseTotalNs = 9; uint32 Uptime = 10;
}
service StatsService {
  rpc GetStats (GetStatsRequest) returns (GetStatsResponse);
  rpc QueryStats (QueryStatsRequest) returns (QueryStatsResponse);
  rpc GetSysStats (SysStatsRequest) returns (SysStatsResponse);
}
EOF_V2V
}

# ---------- grpcurl 管理 ----------

ensure_grpcurl() {
  if [ -x "$GRPCURL_BIN" ]; then
    return 0
  fi
  local asset_pattern tag api api_json tmp_dir download_url
  case "$(uname -m)" in
    x86_64) asset_pattern='linux_x86_64.tar.gz' ;;
    aarch64|arm64) asset_pattern='linux_arm64.tar.gz' ;;
    *)
      warn "当前架构暂不支持自动下载 grpcurl：$(uname -m)"
      return 1
      ;;
  esac
  api="https://api.github.com/repos/fullstorydev/grpcurl/releases/latest"
  api_json="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "$api" 2>/dev/null || true)"
  [ -n "$api_json" ] || { warn "未获取到 grpcurl 最新版本。"; return 1; }
  tag="$(echo "$api_json" | jq -r '.tag_name // empty' 2>/dev/null)" || true
  [ -n "$tag" ] || { warn "未获取到 grpcurl 最新版本。"; return 1; }
  download_url="$(echo "$api_json" | jq -r --arg p "$asset_pattern" '.assets[]?.browser_download_url | select(contains($p))' 2>/dev/null | head -n1)" || true
  [ -n "$download_url" ] || { warn "未找到 grpcurl 适配当前架构的安装包。"; return 1; }
  local checksums_url asset_name expected_sha actual_sha
  checksums_url="$(echo "$api_json" | jq -r '.assets[]?.browser_download_url | select(ascii_downcase | test("checksums?\\.txt$"))' 2>/dev/null | head -n1)" || true
  asset_name="$(basename "$download_url")"
  tmp_dir="$(make_disk_tmp_dir sb-install)" || { warn "创建临时目录失败。"; return 1; }
  say "下载流量统计组件..."
  if ! download_file "$download_url" "$tmp_dir/grpcurl.tar.gz" 20 3; then
    rm -rf "$tmp_dir"
    warn "下载 grpcurl 失败。"
    return 1
  fi
  # 完整性校验：比对官方 release 的 sha256 校验文件，防止下载被篡改
  if [ -n "$checksums_url" ] && curl -fsSL --connect-timeout 20 --retry 3 "$checksums_url" -o "$tmp_dir/checksums.txt" >/dev/null 2>&1; then
    expected_sha="$(awk -v f="$asset_name" '{n=$2; sub(/^.*\//,"",n); if (n==f) {print $1; exit}}' "$tmp_dir/checksums.txt")"
    actual_sha="$(sha256sum "$tmp_dir/grpcurl.tar.gz" | awk '{print $1}')"
    if [ -n "$expected_sha" ] && [ "$expected_sha" != "$actual_sha" ]; then
      rm -rf "$tmp_dir"
      warn "grpcurl 校验失败（sha256 不匹配），已取消安装。"
      return 1
    fi
  else
    warn "未获取到 grpcurl 校验文件，跳过完整性校验。"
  fi
  tar -xzf "$tmp_dir/grpcurl.tar.gz" -C "$tmp_dir" || { rm -rf "$tmp_dir"; warn "解压 grpcurl 失败。"; return 1; }
  [ -f "$tmp_dir/grpcurl" ] || { rm -rf "$tmp_dir"; warn "grpcurl 安装包中未找到 grpcurl。"; return 1; }
  install -m 755 "$tmp_dir/grpcurl" "$GRPCURL_BIN" || { rm -rf "$tmp_dir"; warn "安装 grpcurl 失败。"; return 1; }
  rm -rf "$tmp_dir"
  return 0
}

ensure_grpcurl_logged() {
  if [ -x "$GRPCURL_BIN" ]; then
    return 0
  fi
  if ensure_grpcurl; then
    return 0
  fi
  warn "grpcurl 安装失败，用户流量读数可能不可用。"
  return 1
}

# ---------- V2Ray API 配置注入 ----------

ensure_v2ray_api_on_json() {
  local json="$1"
  local users_json
  users_json="$(
    echo "$json" | jq -c "${JQ_AUTH_USERS}"'
      [
        .route.rules[]?
        | auth_users_array[]?
        | select(length > 0)
      ] | unique | sort
    '
  )"
  echo "$json" | jq --arg listen "$V2RAY_API_LISTEN" --argjson users "$users_json" '
    .experimental = (.experimental // {})
    | .experimental.v2ray_api = (.experimental.v2ray_api // {})
    | .experimental.v2ray_api.listen = $listen
    | .experimental.v2ray_api.stats = {
        "enabled": true,
        "users": $users
      }
  '
}

# ---------- 流量查询 ----------

query_v2ray_api_stats_json() {
  ensure_grpcurl >/dev/null 2>&1 || return 1
  ensure_v2ray_api_proto_files
  local payload out stats
  payload='{"patterns":["user>>>"],"reset":false,"regexp":false}'
  out="$("$GRPCURL_BIN" -plaintext -import-path /etc/sing-box -proto v2rayapi-v2ray.proto -d "$payload" "$V2RAY_API_LISTEN" v2ray.core.app.stats.command.StatsService/QueryStats 2>/dev/null)" || true
  if [ -n "$out" ]; then
    stats="$(echo "$out" | jq -ce 'if .stat != null then .stat else null end' 2>/dev/null)" && {
      echo "$stats"; return 0
    }
  fi
  out="$("$GRPCURL_BIN" -plaintext -import-path /etc/sing-box -proto v2rayapi-experimental.proto -d "$payload" "$V2RAY_API_LISTEN" experimental.v2rayapi.StatsService/QueryStats 2>/dev/null)" || true
  if [ -n "$out" ]; then
    stats="$(echo "$out" | jq -ce 'if .stat != null then .stat else null end' 2>/dev/null)" && {
      echo "$stats"; return 0
    }
  fi
  return 1
}

build_live_usage_object() {
  local stats_json="$1"
  echo "$stats_json" | jq -c '
    reduce (.[]? | select((.name // "") | test("^user>>>.*>>>traffic>>>(downlink|uplink)$"))) as $s
      ({admin:{up:0,down:0}};
        (($s.name // "") | capture("^user>>>(?<user>.+)>>>traffic>>>(?<dir>downlink|uplink)$")) as $m
        | ($m.user) as $uname
        | ($m.dir) as $dir
        | ($s.value // 0 | tonumber? // 0) as $val
        | (if ($uname | contains("@")) then ($uname | split("@")[1]) else "admin" end) as $biz
        | .[$biz] = (.[$biz] // {up:0,down:0})
        | if $dir == "uplink" then
            .[$biz].up = ((.[$biz].up // 0) + $val)
          else
            .[$biz].down = ((.[$biz].down // 0) + $val)
          end
      )
  '
}

sync_user_usage_counters() {
  with_manager_lock _sync_user_usage_counters_body
}

_sync_user_usage_counters_body() {
  user_db_exists || return 0
  [ -x "$GRPCURL_BIN" ] || return 0
  singbox_service_active || return 0

  local stats_json usage_json db_json
  stats_json="$(query_v2ray_api_stats_json)" || return 0
  echo "$stats_json" | jq -e 'type=="array"' >/dev/null 2>&1 || return 0
  usage_json="$(build_live_usage_object "$stats_json")" || return 0
  db_json="$(user_db_load)"
  db_json="$(echo "$db_json" | jq --argjson usage "$usage_json" '
    .users |= with_entries(
      .value as $v
      | ($usage[.key].up // 0) as $live_up
      | ($usage[.key].down // 0) as $live_down
      | ($v.last_live_up_bytes // 0) as $last_up
      | ($v.last_live_down_bytes // 0) as $last_down
      | .value.used_up_bytes = (($v.used_up_bytes // 0) + (if $live_up >= $last_up then ($live_up - $last_up) else $live_up end))
      | .value.used_down_bytes = (($v.used_down_bytes // 0) + (if $live_down >= $last_down then ($live_down - $last_down) else $live_down end))
      | .value.last_live_up_bytes = $live_up
      | .value.last_live_down_bytes = $live_down
    )
  ')" || return 0
  user_db_save "$db_json" || {
    warn "用户流量统计落盘失败：$USER_DB_FILE"
    return 1
  }
}

# ---------- Meta 存储（Reality 公钥等） ----------

meta_load() {
  if [ -s "$META_FILE" ] && jq -e . "$META_FILE" >/dev/null 2>&1; then
    cat "$META_FILE"
  else
    echo '{}'
  fi
}

meta_save() {
  local meta_json="$1"
  mkdir -p "$(dirname "$META_FILE")"
  chmod 700 "$(dirname "$META_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${META_FILE}.tmp.XXXXXX")" || return 1
  if echo "$meta_json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$META_FILE"; then
      err "元数据写入失败：$META_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$META_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file"
    return 1
  fi
}

meta_set_reality_public_key() {
  local tag="$1" public_key="$2"
  [ -n "$tag" ] && [ -n "$public_key" ] || return 0
  local meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --arg t "$tag" --arg pk "$public_key" '.[$t] = ((.[$t] // {}) + {public_key:$pk, private_key_auto_generated:true})')" || return 1
  meta_save "$meta_json"
}

meta_get_reality_public_key() {
  local tag="$1"
  meta_load | jq -r --arg t "$tag" '.[$t].public_key // ""'
}
