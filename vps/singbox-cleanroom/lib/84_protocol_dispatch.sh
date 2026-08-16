subflow_protocol_kind_for_tag() {
  local tag="$1"
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); matches=[item for item in data.get("inbounds", []) if item.get("tag") == sys.argv[2]]; len(matches) == 1 or sys.exit(1); item=matches[0]; kind=item.get("type"); reality=isinstance(item.get("tls"), dict) and isinstance(item["tls"].get("reality"), dict) and item["tls"]["reality"].get("enabled") is True; print("vless-reality" if kind == "vless" and reality else "shadowsocks-2022" if kind == "shadowsocks" and str(item.get("method", "")).startswith("2022-") else kind if kind in {"anytls", "trojan", "tuic"} else "unknown")' \
    "$SUBFLOW_CONFIG_PATH" "$tag"
}

cmd_protocols_add() {
  local protocol="${1:-}"
  shift || true
  case "$protocol" in
    vless-reality) cmd_protocols_add_vless_reality "$@" ;;
    shadowsocks-2022) cmd_protocols_add_shadowsocks_2022 "$@" ;;
    anytls|trojan|tuic) cmd_protocols_add_tls "$protocol" "$@" ;;
    *)
      subflow_fail "当前仅支持新增 vless-reality 或 shadowsocks-2022"
      return 1
      ;;
  esac
}

cmd_protocols_update() {
  local tag="${1:-}" protocol
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  protocol="$(subflow_protocol_kind_for_tag "$tag")" || {
    subflow_fail "未知协议标签: ${tag}"
    return 1
  }
  case "$protocol" in
    vless-reality) cmd_protocols_update_vless_reality "$@" ;;
    shadowsocks-2022) cmd_protocols_update_shadowsocks_2022 "$@" ;;
    anytls|trojan|tuic) cmd_protocols_update_tls "$protocol" "$@" ;;
    *) subflow_fail "协议暂不支持更新: ${tag}"; return 1 ;;
  esac
}

cmd_protocols_delete() {
  local tag="${1:-}" protocol
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  protocol="$(subflow_protocol_kind_for_tag "$tag")" || {
    subflow_fail "未知协议标签: ${tag}"
    return 1
  }
  case "$protocol" in
    vless-reality) cmd_protocols_delete_vless_reality "$@" ;;
    shadowsocks-2022) cmd_protocols_delete_shadowsocks_2022 "$@" ;;
    anytls|trojan|tuic) cmd_protocols_delete_tls "$protocol" "$@" ;;
    *) subflow_fail "协议暂不支持删除: ${tag}"; return 1 ;;
  esac
}