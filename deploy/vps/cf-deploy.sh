#!/usr/bin/env bash

# ============================================================
# subflow Cloudflare Pages auto-deploy (Direct Upload)
# ============================================================
# Optional, fully automated Cloudflare deployment. It uses Wrangler "Direct
# Upload" so it needs ONLY a Cloudflare API Token + Account ID. It does NOT need
# you to fork the repo and does NOT need a GitHub token — the Pages assets
# (functions/) are uploaded directly from the copy already on this machine.
#
# Steps performed (each explained inline as it runs):
#   1. collect Cloudflare credentials + your domain names (with explanations)
#   2. verify the token and resolve the zone id from your root domain
#   3. create the Pages project (if missing) and upload functions/
#   4. set the VPS_API_BASE_URL + VPS_API_BEARER_TOKEN secrets
#   5. create the api.<sub> DNS record pointing at this VPS
#   6. attach the subscription custom domain to the Pages project
#   7. print the final subscription URL
#
# Can be run standalone, from install.sh, or via `sf` → Cloudflare 部署.
# ============================================================

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ----- Locate the Pages assets (functions/) ----------------------------------
resolve_pages_dir() {
  # Prefer the installed copy; fall back to a repo checkout next to this script.
  if [[ -d "${PAGES_ROOT}/functions" ]]; then
    PAGES_DIR="${PAGES_ROOT}"
    return 0
  fi
  local repo_root
  repo_root="$(cd -- "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || true)"
  if [[ -n "${repo_root}" && -d "${repo_root}/functions" ]]; then
    PAGES_DIR="${repo_root}"
    return 0
  fi
  err "未找到 Pages 资源 (functions/)。请先完成 VPS 安装。"
  exit 1
}

# ----- Tooling prerequisites -------------------------------------------------
require_node_npx() {
  if command -v npx >/dev/null 2>&1; then
    return 0
  fi
  warn "未检测到 Node.js / npx（Wrangler 直传需要 Node 18+）。"
  printf '%b\n' "    ${C_GREY}Debian/Ubuntu 可执行： curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs${C_RESET}"
  printf '%b' "  ${C_PINK}现在尝试自动安装 Node 20？[y/N]${C_RESET}: "
  local c; read -r c || c="n"
  if [[ "${c}" =~ ^[yY] ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
    else
      err "无法自动安装（未找到 apt-get）。请手动安装 Node 18+ 后重试。"
      exit 1
    fi
  else
    err "已取消。请安装 Node 18+ 后重试，或在本地机器手动部署。"
    exit 1
  fi
}

# ----- Prompt helpers --------------------------------------------------------
# ask VAR "label" "explanation" "default" "secret(yes/no)"
ask() {
  local __var="$1" label="$2" explain="$3" def="${4:-}" secret="${5:-no}"
  printf '%b\n' ""
  printf '%b\n' "  ${C_LAV}${C_BOLD}${label}${C_RESET}"
  printf '%b\n' "    ${C_GREY}${explain}${C_RESET}"
  local hint
  if [[ -n "${def}" ]]; then
    hint="${C_GREY}[回车=默认 ${def}]${C_RESET}"
  else
    hint="${C_YELLOW}[必填]${C_RESET}"
  fi
  while true; do
    printf '%b' "    ${C_PINK}输入${C_RESET} ${hint}: "
    local reply
    if [[ "${secret}" == "yes" ]]; then
      read -r -s reply || reply=""; printf '\n'
    else
      read -r reply || reply=""
    fi
    if [[ -z "${reply}" ]]; then
      if [[ -n "${def}" ]]; then printf -v "${__var}" '%s' "${def}"; return 0; fi
      warn "该项必填。"; continue
    fi
    printf -v "${__var}" '%s' "${reply}"
    return 0
  done
}

# ----- Main wizard -----------------------------------------------------------
collect_inputs() {
  printf '%b\n' ""
  step "Cloudflare 自动部署向导（直传 + Cloudflare Tunnel，无需 fork / GitHub Token）"
  printf '%b\n' "  ${C_GREY}需要一个 Cloudflare API Token，共 4 项权限："
  printf '%b\n' "  ${C_GREY}  • Account → Cloudflare Pages → Edit"
  printf '%b\n' "  ${C_GREY}  • Account → Cloudflare Tunnel → Edit"
  printf '%b\n' "  ${C_GREY}  • Zone → DNS → Edit"
  printf '%b\n' "  ${C_GREY}  • Zone → Zone → Read"
  printf '%b\n' "  ${C_GREY}Token 仅运行时使用，不会写入磁盘。${C_RESET}"

  ask CF_TOKEN "Cloudflare API Token" \
    "在 dash.cloudflare.com → 右上头像 → My Profile → API Tokens → Create Token 创建。" \
    "" "yes"

  ask CF_ACCOUNT_ID "Cloudflare Account ID" \
    "在任意域名的 Overview 页右侧 API 区域可见，是一串 32 位十六进制。" \
    ""

  ask ROOT_DOMAIN "根域名 (Zone)" \
    "你已托管在 Cloudflare 的主域名，例如 example.com。脚本会据此自动查 Zone ID。" \
    ""

  ask SUB_HOST "订阅子域 (面向用户)" \
    "用户拿订阅的入口，将绑定到 Pages。例如 subflow.${ROOT_DOMAIN}" \
    "subflow.${ROOT_DOMAIN}"

  ask API_HOST "API 子域 (面向 Pages 回源)" \
    "Pages 用它访问本 VPS 的数据 API。将通过 Cloudflare Tunnel 回源到本机，无需开放任何入站端口。例如 api.${SUB_HOST}" \
    "api.${SUB_HOST}"

  ask PROJECT_NAME "Pages 项目名" \
    "Cloudflare Pages 项目的名称（小写字母/数字/连字符）。" \
    "subflow"

  # Token used by Cloudflare to talk to the VPS API. Reuse the installed one.
  load_env
  CF_BEARER="${CFG_VALUE[SUBFLOW_API_TOKEN]:-}"
  if [[ -z "${CF_BEARER}" ]]; then
    CF_BEARER="$(generate_token)"
    warn "未找到现有 VPS Token，已生成一个新的（请确保 VPS 端也使用它）。"
  fi
  # Local origin the tunnel forwards to (the data API binds here).
  ORIGIN_URL="http://${CFG_VALUE[SUBFLOW_LISTEN_HOST]:-127.0.0.1}:${CFG_VALUE[SUBFLOW_LISTEN_PORT]:-28080}"
}

confirm_inputs() {
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}${C_BOLD}请确认 Cloudflare 部署配置${C_RESET}"
  printf '%b\n' "    ${C_GREY}Account ID${C_RESET}   = ${C_LAV}${CF_ACCOUNT_ID}${C_RESET}"
  printf '%b\n' "    ${C_GREY}根域名${C_RESET}       = ${C_LAV}${ROOT_DOMAIN}${C_RESET}"
  printf '%b\n' "    ${C_GREY}订阅子域${C_RESET}     = ${C_LAV}${SUB_HOST}${C_RESET}  ${C_GREY}(Pages)${C_RESET}"
  printf '%b\n' "    ${C_GREY}API 子域${C_RESET}     = ${C_LAV}${API_HOST}${C_RESET}  ${C_GREY}→ Tunnel → ${ORIGIN_URL}${C_RESET}"
  printf '%b\n' "    ${C_GREY}Pages 项目名${C_RESET} = ${C_LAV}${PROJECT_NAME}${C_RESET}"
  printf '%b\n' "    ${C_GREY}VPS_API_BASE_URL${C_RESET} = ${C_LAV}https://${API_HOST}${C_RESET}"
  printf '%b\n' ""
  printf '%b' "  ${C_PINK}确认并开始部署？[Y/n]${C_RESET}: "
  local c; read -r c || c="y"
  [[ -z "${c}" || "${c}" =~ ^[yY] ]]
}

# ----- Cloudflare operations -------------------------------------------------
verify_token() {
  step "校验 API Token…"
  local resp ok_field
  resp="$(cf_api "${CF_TOKEN}" GET "/user/tokens/verify")"
  ok_field="$(json_get "${resp}" "d.get('success')")"
  if [[ "${ok_field}" != "True" ]]; then
    err "Token 校验失败，请检查权限/有效性。"
    exit 1
  fi
  ok "Token 有效。"
}

resolve_zone() {
  step "查询 Zone ID（${ROOT_DOMAIN}）…"
  local resp
  resp="$(cf_api "${CF_TOKEN}" GET "/zones?name=${ROOT_DOMAIN}")"
  ZONE_ID="$(json_get "${resp}" "d['result'][0]['id'] if d.get('result') else ''")"
  if [[ -z "${ZONE_ID}" ]]; then
    err "未找到 Zone：${ROOT_DOMAIN}。请确认该域名已托管在此 Cloudflare 账户。"
    exit 1
  fi
  ok "Zone ID: ${ZONE_ID}"
}

ensure_project() {
  step "确认/创建 Pages 项目（${PROJECT_NAME}）…"
  local resp exists
  resp="$(cf_api "${CF_TOKEN}" GET "/accounts/${CF_ACCOUNT_ID}/pages/projects/${PROJECT_NAME}")"
  exists="$(json_get "${resp}" "d.get('success')")"
  if [[ "${exists}" == "True" ]]; then
    PROJECT_SUBDOMAIN="$(json_get "${resp}" "d['result'].get('subdomain','') if d.get('result') else ''")"
    ok "项目已存在，复用（${PROJECT_SUBDOMAIN:-未知子域}）。"
    return 0
  fi
  local body
  body="$(printf '{"name":"%s","production_branch":"main"}' "${PROJECT_NAME}")"
  resp="$(cf_api "${CF_TOKEN}" POST "/accounts/${CF_ACCOUNT_ID}/pages/projects" "${body}")"
  if [[ "$(json_get "${resp}" "d.get('success')")" != "True" ]]; then
    err "创建 Pages 项目失败：$(json_get "${resp}" "d.get('errors')")"
    exit 1
  fi
  PROJECT_SUBDOMAIN="$(json_get "${resp}" "d['result'].get('subdomain','') if d.get('result') else ''")"
  ok "项目已创建（${PROJECT_SUBDOMAIN:-未知子域}）。"
}

deploy_assets() {
  step "上传 Pages 资源（functions/）via Wrangler 直传…"
  # Isolate wrangler's config dir to a throwaway location. A pre-existing
  # ~/.config/.wrangler (e.g. a stale OAuth login from earlier wrangler use)
  # can take precedence over CLOUDFLARE_API_TOKEN and cause auth code 10001
  # even when the token itself is valid. A clean XDG_CONFIG_HOME forces
  # wrangler to fall back to the env token we pass in. Also drop any legacy
  # CLOUDFLARE_API_KEY/EMAIL so they cannot shadow the token.
  local cfg_home rc=0
  cfg_home="$(mktemp -d)"
  ( cd "${PAGES_DIR}" && \
    env -u CLOUDFLARE_API_KEY -u CLOUDFLARE_EMAIL \
      CLOUDFLARE_API_TOKEN="${CF_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" \
      XDG_CONFIG_HOME="${cfg_home}" \
      npx --yes wrangler@4 pages deploy \
        --project-name "${PROJECT_NAME}" \
        --branch main \
        --commit-dirty=true ) || rc=$?
  rm -rf "${cfg_home}"
  if [[ "${rc}" -ne 0 ]]; then
    err "Pages 资源上传失败（wrangler 退出码 ${rc}）。请确认 Token 含 Cloudflare Pages → Edit 后重跑 sf deploy。"
    exit 1
  fi
  ok "部署完成。"
}

set_secrets() {
  step "写入 Pages 机密（VPS_API_BASE_URL / VPS_API_BEARER_TOKEN）…"
  # Set secrets via the REST API instead of `wrangler pages secret put`.
  # The REST path uses the same Bearer token that already authenticates here,
  # avoiding wrangler's credential-resolution quirks (auth code 10001). The
  # values are written as encrypted project-level production env vars, which
  # the subsequent deploy inherits. Missing secrets make the live site return
  # 500 ("Service unavailable"), so surface a warning instead of failing hard.
  local body resp
  body="$(python3 -c 'import json,sys
print(json.dumps({"deployment_configs":{"production":{"env_vars":{
  "VPS_API_BASE_URL":{"type":"secret_text","value":sys.argv[1]},
  "VPS_API_BEARER_TOKEN":{"type":"secret_text","value":sys.argv[2]}}}}}))' \
    "https://${API_HOST}" "${CF_BEARER}")"
  resp="$(cf_api "${CF_TOKEN}" PATCH "/accounts/${CF_ACCOUNT_ID}/pages/projects/${PROJECT_NAME}" "${body}")"
  if [[ "$(json_get "${resp}" "d.get('success')")" == "True" ]]; then
    ok "已设置 VPS_API_BASE_URL 与 VPS_API_BEARER_TOKEN。"
  else
    warn "机密写入可能失败：$(json_get "${resp}" "d.get('errors')")。若站点返回 Service unavailable，请检查 Token 权限后重跑 sf deploy。"
  fi
}

# ----- Cloudflare Tunnel (exposes the localhost API without opening ports) ----
# The data API binds to 127.0.0.1 only. The VPS likely already uses :443 for the
# sing-box node, so a reverse proxy is not an option. cloudflared dials OUT to
# Cloudflare, so no inbound port is opened and the node's :443 is untouched.

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared 已安装。"
    return 0
  fi
  step "安装 cloudflared…"
  local arch deb_arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) deb_arch="amd64" ;;
    aarch64|arm64) deb_arch="arm64" ;;
    armv7l|armhf) deb_arch="arm" ;;
    *) deb_arch="" ;;
  esac
  if [[ -z "${deb_arch}" ]]; then
    err "未知 CPU 架构 ${arch}，请手动安装 cloudflared 后重试。"
    exit 1
  fi
  local base="https://github.com/cloudflare/cloudflared/releases/latest/download"
  # Prefer the .deb (apt keeps it updated), but never let a failed download abort
  # the whole script under `set -e`; fall back to the static binary, then verify
  # the result actually runs before continuing.
  if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    local deb="/tmp/cloudflared-${deb_arch}.deb"
    if curl -fsSL --retry 3 "${base}/cloudflared-linux-${deb_arch}.deb" -o "${deb}" 2>/dev/null; then
      dpkg -i "${deb}" >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1 || true
      rm -f "${deb}"
    fi
  fi
  if ! command -v cloudflared >/dev/null 2>&1; then
    # Fallback: drop the static binary in place. Clean up a partial file so a
    # half-written binary is never left behind on a flaky connection.
    if ! curl -fsSL --retry 3 "${base}/cloudflared-linux-${deb_arch}" -o /usr/local/bin/cloudflared 2>/dev/null; then
      rm -f /usr/local/bin/cloudflared
      err "cloudflared 下载失败（无法连接 GitHub）。请检查 VPS 网络或手动安装后重跑 sf deploy。"
      exit 1
    fi
    chmod +x /usr/local/bin/cloudflared
  fi
  if cloudflared --version >/dev/null 2>&1; then
    ok "cloudflared 安装完成（$(cloudflared --version 2>/dev/null | head -n1)）。"
  else
    err "cloudflared 已下载但无法运行（架构 ${arch} 不匹配？）。请手动安装后重跑 sf deploy。"
    exit 1
  fi
}

ensure_tunnel() {
  step "创建/复用 Cloudflare Tunnel（${PROJECT_NAME}）…"
  # Reuse an existing tunnel by name if present (not deleted).
  local resp
  resp="$(cf_api "${CF_TOKEN}" GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${PROJECT_NAME}&is_deleted=false")"
  TUNNEL_ID="$(json_get "${resp}" "d['result'][0]['id'] if d.get('result') else ''")"
  if [[ -z "${TUNNEL_ID}" ]]; then
    local body
    body="$(printf '{"name":"%s","config_src":"cloudflare"}' "${PROJECT_NAME}")"
    resp="$(cf_api "${CF_TOKEN}" POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "${body}")"
    TUNNEL_ID="$(json_get "${resp}" "d['result'].get('id','') if d.get('result') else ''")"
  fi
  if [[ -z "${TUNNEL_ID}" ]]; then
    err "创建 Tunnel 失败：$(json_get "${resp}" "d.get('errors')")（请确认 Token 含 Account → Cloudflare Tunnel → Edit）。"
    exit 1
  fi
  ok "Tunnel ID: ${TUNNEL_ID}"
}

configure_tunnel() {
  step "配置 Tunnel 入口：${API_HOST} → ${ORIGIN_URL}…"
  local body resp
  body="$(printf '{"config":{"ingress":[{"hostname":"%s","service":"%s"},{"service":"http_status:404"}]}}' "${API_HOST}" "${ORIGIN_URL}")"
  resp="$(cf_api "${CF_TOKEN}" PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "${body}")"
  if [[ "$(json_get "${resp}" "d.get('success')")" == "True" ]]; then
    ok "Tunnel 入口已配置。"
  else
    err "配置 Tunnel 入口失败：$(json_get "${resp}" "d.get('errors')")。"
    exit 1
  fi
}

install_tunnel_service() {
  step "安装并启动 cloudflared 系统服务…"
  local resp token
  resp="$(cf_api "${CF_TOKEN}" GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")"
  token="$(json_get "${resp}" "d.get('result','')")"
  if [[ -z "${token}" ]]; then
    err "获取 Tunnel 运行 Token 失败：$(json_get "${resp}" "d.get('errors')")。"
    exit 1
  fi
  # Idempotent: remove any previous install before reinstalling with the token.
  cloudflared service uninstall >/dev/null 2>&1 || true
  if cloudflared service install "${token}" >/dev/null 2>&1; then
    systemctl enable --now cloudflared >/dev/null 2>&1 || true
    ok "cloudflared 服务已运行（仅出站连接，未开放任何入站端口）。"
  else
    warn "cloudflared 服务安装可能失败，可手动运行：cloudflared service install <token>。"
  fi
}

ensure_dns_api() {
  step "创建/更新 DNS：${API_HOST} → Tunnel（CNAME，橙云）…"
  # Point the api host at the tunnel. Orange-cloud (proxied) is required so
  # Cloudflare terminates TLS and routes through the tunnel.
  local resp rec_id body target
  target="${TUNNEL_ID}.cfargotunnel.com"
  resp="$(cf_api "${CF_TOKEN}" GET "/zones/${ZONE_ID}/dns_records?name=${API_HOST}")"
  rec_id="$(json_get "${resp}" "d['result'][0]['id'] if d.get('result') else ''")"
  body="$(printf '{"type":"CNAME","name":"%s","content":"%s","proxied":true,"ttl":1}' "${API_HOST}" "${target}")"
  if [[ -n "${rec_id}" ]]; then
    resp="$(cf_api "${CF_TOKEN}" PUT "/zones/${ZONE_ID}/dns_records/${rec_id}" "${body}")"
  else
    resp="$(cf_api "${CF_TOKEN}" POST "/zones/${ZONE_ID}/dns_records" "${body}")"
  fi
  if [[ "$(json_get "${resp}" "d.get('success')")" == "True" ]]; then
    ok "DNS 就绪（${API_HOST} → ${target}）。"
  else
    warn "DNS 设置可能失败：$(json_get "${resp}" "d.get('errors')")，可在面板手动添加 CNAME ${API_HOST} → ${target}。"
  fi
}

attach_domain() {
  step "绑定订阅自定义域到 Pages：${SUB_HOST}…"
  local body resp
  body="$(printf '{"name":"%s"}' "${SUB_HOST}")"
  resp="$(cf_api "${CF_TOKEN}" POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/${PROJECT_NAME}/domains" "${body}")"
  if [[ "$(json_get "${resp}" "d.get('success')")" == "True" ]]; then
    ok "已请求绑定（Cloudflare 会自动签发证书，可能需要几分钟）。"
  else
    warn "绑定可能失败：$(json_get "${resp}" "d.get('errors')")，可在 Pages 面板手动添加自定义域。"
  fi
}

ensure_dns_sub() {
  # Attaching the custom domain does NOT create the validating DNS record, so the
  # domain stays "pending". Create/update a proxied CNAME SUB_HOST -> *.pages.dev
  # to complete validation automatically.
  if [[ -z "${PROJECT_SUBDOMAIN:-}" ]]; then
    warn "未取得 Pages 子域，跳过订阅域 CNAME；请在面板手动添加 ${SUB_HOST} → <项目>.pages.dev。"
    return 0
  fi
  step "创建/更新 DNS：${SUB_HOST} → ${PROJECT_SUBDOMAIN}（CNAME，橙云）…"
  local resp rec_id body
  resp="$(cf_api "${CF_TOKEN}" GET "/zones/${ZONE_ID}/dns_records?name=${SUB_HOST}")"
  rec_id="$(json_get "${resp}" "d['result'][0]['id'] if d.get('result') else ''")"
  body="$(printf '{"type":"CNAME","name":"%s","content":"%s","proxied":true,"ttl":1}' "${SUB_HOST}" "${PROJECT_SUBDOMAIN}")"
  if [[ -n "${rec_id}" ]]; then
    resp="$(cf_api "${CF_TOKEN}" PUT "/zones/${ZONE_ID}/dns_records/${rec_id}" "${body}")"
  else
    resp="$(cf_api "${CF_TOKEN}" POST "/zones/${ZONE_ID}/dns_records" "${body}")"
  fi
  if [[ "$(json_get "${resp}" "d.get('success')")" == "True" ]]; then
    ok "订阅域 CNAME 就绪，Cloudflare 将自动完成校验与签发证书。"
  else
    warn "订阅域 CNAME 设置可能失败：$(json_get "${resp}" "d.get('errors')")，可在面板手动添加 CNAME ${SUB_HOST} → ${PROJECT_SUBDOMAIN}。"
  fi
}

print_result() {
  printf '%b\n' ""
  ok "Cloudflare 部署完成啦～ ♡(◕‿◕)♡"
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}订阅入口:${C_RESET} ${C_BOLD}https://${SUB_HOST}/<用户名>${C_RESET}"
  printf '%b\n' "  ${C_CYAN}例如:${C_RESET}    https://${SUB_HOST}/alice?format=clash"
  printf '%b\n' "  ${C_CYAN}回源 API:${C_RESET} https://${API_HOST}  → Cloudflare Tunnel → ${ORIGIN_URL}"
  printf '%b\n' "  ${C_GREY}提示：Tunnel 仅出站连接，未开放任何入站端口，不影响节点 :443。${C_RESET}"
  printf '%b\n' "  ${C_GREY}DNS/证书可能需要几分钟生效。以后更新可运行：sf → Cloudflare 重新部署${C_RESET}"
}

main() {
  require_root
  init_config_meta
  require_downloader
  resolve_pages_dir
  require_node_npx

  clear 2>/dev/null || true
  banner
  collect_inputs
  while ! confirm_inputs; do
    warn "重新填写一次～"
    collect_inputs
  done

  verify_token
  resolve_zone
  ensure_project
  # Secrets must exist BEFORE the deployment that serves them, otherwise the live
  # site returns 500 "Service unavailable" until the next deploy.
  set_secrets
  deploy_assets
  # Expose the localhost API through a Cloudflare Tunnel (no inbound ports).
  ensure_cloudflared
  ensure_tunnel
  configure_tunnel
  install_tunnel_service
  ensure_dns_api
  attach_domain
  ensure_dns_sub
  print_result
}

main "$@"
