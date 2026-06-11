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
  step "Cloudflare 自动部署向导（直传方式，无需 fork、无需 GitHub Token）"
  printf '%b\n' "  ${C_GREY}需要一个 Cloudflare API Token，权限：Account → Cloudflare Pages → Edit，"
  printf '%b\n' "  以及 Zone → DNS → Edit（用于自动创建 api 子域解析）。Token 不会写入磁盘。${C_RESET}"

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
    "Pages 用它来访问本 VPS 的数据 API，将解析到本机公网 IP。例如 api.${SUB_HOST}" \
    "api.${SUB_HOST}"

  local ip_guess; ip_guess="$(detect_public_ip)"
  ask ORIGIN_IP "本 VPS 公网 IP" \
    "api 子域将解析到这个地址（即 Pages 回源访问的目标）。" \
    "${ip_guess}"

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
}

confirm_inputs() {
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}${C_BOLD}请确认 Cloudflare 部署配置${C_RESET}"
  printf '%b\n' "    ${C_GREY}Account ID${C_RESET}   = ${C_LAV}${CF_ACCOUNT_ID}${C_RESET}"
  printf '%b\n' "    ${C_GREY}根域名${C_RESET}       = ${C_LAV}${ROOT_DOMAIN}${C_RESET}"
  printf '%b\n' "    ${C_GREY}订阅子域${C_RESET}     = ${C_LAV}${SUB_HOST}${C_RESET}  ${C_GREY}(Pages)${C_RESET}"
  printf '%b\n' "    ${C_GREY}API 子域${C_RESET}     = ${C_LAV}${API_HOST}${C_RESET}  ${C_GREY}→ ${ORIGIN_IP}${C_RESET}"
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
  ( cd "${PAGES_DIR}" && \
    CLOUDFLARE_API_TOKEN="${CF_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" \
    npx --yes wrangler@3 pages deploy \
      --project-name "${PROJECT_NAME}" \
      --branch main \
      --commit-dirty=true )
  ok "部署完成。"
}

set_secrets() {
  step "写入 Pages 环境变量与机密…"
  # Secrets via wrangler (encrypted). Non-interactive: pipe value to stdin.
  # Keep failures visible: missing secrets cause the live site to 500
  # ("Service unavailable"), so surface a warning instead of swallowing errors.
  local rc=0
  ( cd "${PAGES_DIR}" && \
    printf '%s' "https://${API_HOST}" | CLOUDFLARE_API_TOKEN="${CF_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" \
      npx --yes wrangler@3 pages secret put VPS_API_BASE_URL --project-name "${PROJECT_NAME}" ) || rc=1
  ( cd "${PAGES_DIR}" && \
    printf '%s' "${CF_BEARER}" | CLOUDFLARE_API_TOKEN="${CF_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" \
      npx --yes wrangler@3 pages secret put VPS_API_BEARER_TOKEN --project-name "${PROJECT_NAME}" ) || rc=1
  if [[ "${rc}" -eq 0 ]]; then
    ok "已设置 VPS_API_BASE_URL 与 VPS_API_BEARER_TOKEN。"
  else
    warn "机密写入可能失败；若站点返回 Service unavailable，请检查 Token 权限后重跑 sf deploy。"
  fi
}

ensure_dns_api() {
  step "创建/更新 DNS：${API_HOST} → ${ORIGIN_IP}…"
  # Look up existing record.
  local resp rec_id
  resp="$(cf_api "${CF_TOKEN}" GET "/zones/${ZONE_ID}/dns_records?type=A&name=${API_HOST}")"
  rec_id="$(json_get "${resp}" "d['result'][0]['id'] if d.get('result') else ''")"
  # api host is plain origin (grey cloud / proxied=false) so Pages can reach it.
  local body
  body="$(printf '{"type":"A","name":"%s","content":"%s","proxied":false,"ttl":120}' "${API_HOST}" "${ORIGIN_IP}")"
  if [[ -n "${rec_id}" ]]; then
    resp="$(cf_api "${CF_TOKEN}" PUT "/zones/${ZONE_ID}/dns_records/${rec_id}" "${body}")"
  else
    resp="$(cf_api "${CF_TOKEN}" POST "/zones/${ZONE_ID}/dns_records" "${body}")"
  fi
  if [[ "$(json_get "${resp}" "d.get('success')")" == "True" ]]; then
    ok "DNS 就绪（未开启橙云代理，便于 Pages 回源）。"
  else
    warn "DNS 设置可能失败：$(json_get "${resp}" "d.get('errors')")，可稍后在面板手动添加 A 记录。"
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
  printf '%b\n' "  ${C_CYAN}回源 API:${C_RESET} https://${API_HOST}  → 本 VPS"
  printf '%b\n' "  ${C_GREY}提示：DNS/证书可能需要几分钟生效。以后更新可运行：sf → Cloudflare 重新部署${C_RESET}"
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
  ensure_dns_api
  attach_domain
  ensure_dns_sub
  print_result
}

main "$@"
