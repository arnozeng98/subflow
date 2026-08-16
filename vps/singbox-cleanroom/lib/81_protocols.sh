subflow_protocol_registry() {
  cat <<'EOF'
vless-reality|vless|tcp|443|yes
anytls|anytls|tcp|443|yes
shadowsocks-2022|shadowsocks|tcp,udp|8388|yes
trojan|trojan|tcp|443|yes
vmess-ws|vmess|tcp|10000|yes
vless-ws|vless|tcp|10001|yes
tuic|tuic|udp|443|yes
EOF
}

subflow_protocol_is_supported() {
  local protocol="$1" record
  while IFS= read -r record; do
    [[ "${record%%|*}" == "$protocol" ]] && return 0
  done < <(subflow_protocol_registry)
  return 1
}

subflow_protocol_validate_tag() {
  local tag="$1"
  if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    subflow_fail "协议标签不合法: ${tag}"
    return 1
  fi
}

subflow_protocol_validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    subflow_fail "端口不合法: ${port}"
    return 1
  fi
}

subflow_protocol_validate_server_name() {
  local server_name="$1"
  if [[ ${#server_name} -gt 253 || ! "$server_name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ \
    || "$server_name" != *.* || "$server_name" == *..* ]]; then
    subflow_fail "服务器名称不合法: ${server_name}"
    return 1
  fi
}

subflow_protocol_validate_email() {
  local email="$1"
  if [[ ${#email} -gt 254 || "$email" == *[[:space:]]* || "$email" != *@*.* ]]; then
    subflow_fail "ACME 邮箱不合法: ${email}"
    return 1
  fi
}

subflow_protocol_list() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if ! subflow_require_cmd python3; then
    subflow_lock_release
    return 1
  fi
  if [[ ! -f "$SUBFLOW_CONFIG_PATH" ]]; then
    subflow_lock_release
    subflow_fail "缺少文件: ${SUBFLOW_CONFIG_PATH}"
    return 1
  fi

  python3 - "$SUBFLOW_CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("标签 | 协议 | 端口 | 用户数")
for inbound in sorted(payload.get("inbounds", []), key=lambda item: str(item.get("tag", ""))):
    inbound_type = inbound.get("type", "unknown")
    transport_type = (inbound.get("transport") or {}).get("type")
    reality_enabled = ((inbound.get("tls") or {}).get("reality") or {}).get("enabled") is True
    if inbound_type == "vless" and reality_enabled:
        protocol = "vless-reality"
    elif inbound_type == "vless" and transport_type == "ws":
        protocol = "vless-ws"
    elif inbound_type == "vmess" and transport_type == "ws":
        protocol = "vmess-ws"
    elif inbound_type == "shadowsocks":
        protocol = "shadowsocks-2022"
    else:
        protocol = inbound_type
    print(f"{inbound.get('tag', '')} | {protocol} | {inbound.get('listen_port', '')} | {len(inbound.get('users', []))}")
PY
  local status=$?
  subflow_lock_release
  return $status
}

cmd_protocols_dispatch() {
  local subcmd="${1:-list}"
  shift || true
  case "$subcmd" in
    list)
      [[ "$#" -eq 0 ]] || { subflow_fail "protocols list 不接受参数"; return 1; }
      subflow_protocol_list
      ;;
    registry)
      [[ "$#" -eq 0 ]] || { subflow_fail "protocols registry 不接受参数"; return 1; }
      subflow_protocol_registry
      ;;
    add)
      cmd_protocols_add "$@"
      ;;
    update)
      cmd_protocols_update "$@"
      ;;
    delete)
      cmd_protocols_delete "$@"
      ;;
    *)
      subflow_fail "未知 protocols 子命令: ${subcmd}"
      return 1
      ;;
  esac
}