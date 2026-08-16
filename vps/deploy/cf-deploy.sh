#!/usr/bin/env bash

# ============================================================
# subflow Cloudflare Pages 自动部署（直接上传）
# ============================================================
# 可选的全自动 Cloudflare 部署。它使用 Wrangler“直接上传”，因此只需要
# Cloudflare API 令牌和账户 ID。无需复刻仓库，也无需 GitHub 令牌；Pages 资源
#（functions/）会直接从本机已有的副本上传。
#
# 执行步骤（运行时会逐项说明）：
#   1. 收集 Cloudflare 凭据和域名（附说明）
#   2. 验证令牌，并根据根域名解析区域 ID
#   3. 创建 Pages 项目（如果不存在）并上传 functions/
#   4. 设置 VPS_API_BASE_URL 和 VPS_API_BEARER_TOKEN 机密
#   5. 创建指向此 VPS 的 api.<sub> DNS 记录
#   6. 将订阅自定义域绑定到 Pages 项目
#   7. 打印最终订阅 URL
#
# 可独立运行、从 install.sh 运行，或通过 `sf` → Cloudflare 部署运行。
# ============================================================

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=dependencies.sh
source "${SCRIPT_DIR}/dependencies.sh"

# ----- 定位 Pages 资源（functions/）-------------------------------------------
resolve_pages_dir() {
  # 优先使用已安装的副本；否则使用此脚本旁的仓库检出目录。
  if [[ -d "${PAGES_ROOT}/functions" ]]; then
    PAGES_DIR="${PAGES_ROOT}"
    return 0
  fi
  local repo_root
  repo_root="$(cd -- "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || true)"
  if [[ -n "${repo_root}" && -d "${repo_root}/cloudflare/functions" ]]; then
    PAGES_DIR="${repo_root}/cloudflare"
    return 0
  fi
  err "未找到 Pages 资源 (functions/)。请先完成 VPS 安装。"
  exit 1
}

# ----- 工具先决条件 -----------------------------------------------------------
node_major_version() {
  local version
  version="$(node --version 2>/dev/null || true)"
  version="${version#v}"
  version="${version%%.*}"
  [[ "${version}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${version}"
}

node_npx_supported() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1
  command -v npx >/dev/null 2>&1 || return 1
  local major
  major="$(node_major_version)" || return 1
  (( major >= WRANGLER_NODE_MIN_MAJOR ))
}

require_node_npx() {
  if node_npx_supported; then
    return 0
  fi

  local current="未安装" package_manager
  if command -v node >/dev/null 2>&1; then
    current="$(node --version 2>/dev/null || printf '无法识别')"
  fi
  warn "Wrangler ${WRANGLER_VERSION} 需要 Node ${WRANGLER_NODE_MIN_MAJOR}+ 及 npm/npx（当前：${current}）。"
  printf '%b' "  ${C_PINK}是否通过系统包管理器安装/更新 nodejs 与 npm？[y/N]${C_RESET}: "
  local c; read -r c || c="n"
  if [[ ! "${c}" =~ ^[yY] ]]; then
    err "已取消。请通过可信的软件源安装 Node ${WRANGLER_NODE_MIN_MAJOR}+ 与 npm 后重试。"
    exit 1
  fi

  package_manager="$(detect_package_manager 2>/dev/null || true)"
  if [[ -z "${package_manager}" ]]; then
    err "无法识别系统包管理器，请手动安装 Node ${WRANGLER_NODE_MIN_MAJOR}+ 与 npm。"
    exit 1
  fi
  if ! install_packages "${package_manager}" nodejs npm; then
    err "通过 ${package_manager} 安装 nodejs/npm 失败。"
    exit 1
  fi

  if ! node_npx_supported; then
    current="$(node --version 2>/dev/null || printf '未安装')"
    err "系统软件源提供的 Node 版本不满足要求（当前：${current}，要求：${WRANGLER_NODE_MIN_MAJOR}+）。"
    err "请改用该发行版可信的软件源安装新版 Node 后重试；脚本不会执行远程 shell 安装器。"
    exit 1
  fi
}

verify_wrangler_package() {
  local actual_integrity
  actual_integrity="$(npm view "wrangler@${WRANGLER_VERSION}" dist.integrity --json 2>/dev/null | tr -d '\r\n\"' || true)"
  if [[ -z "${actual_integrity}" ]]; then
    err "未能读取 Wrangler ${WRANGLER_VERSION} 的 npm 完整性信息。"
    return 1
  fi
  if [[ "${actual_integrity}" != "${WRANGLER_INTEGRITY}" ]]; then
    err "Wrangler ${WRANGLER_VERSION} 的 npm integrity 与项目锁定值不一致，已停止部署。"
    return 1
  fi
}

# ----- 提示辅助函数 -----------------------------------------------------------
# ask VAR "标签" "说明" "默认值" "机密(yes/no)"
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

# ----- 主向导 ----------------------------------------------------------------
collect_inputs() {
  printf '%b\n' ""
  step "Cloudflare 自动部署向导（直传 + Cloudflare Tunnel，无需复刻仓库或 GitHub 令牌）"
  printf '%b\n' "  ${C_GREY}需要一个 Cloudflare API 令牌，共 4 项权限："
  printf '%b\n' "  ${C_GREY}  • 账户 → Cloudflare Pages → 编辑"
  printf '%b\n' "  ${C_GREY}  • 账户 → Cloudflare Tunnel → 编辑"
  printf '%b\n' "  ${C_GREY}  • 区域 → DNS → 编辑"
  printf '%b\n' "  ${C_GREY}  • 区域 → 区域 → 读取"
  printf '%b\n' "  ${C_GREY}令牌仅运行时使用，不会写入磁盘。${C_RESET}"

  ask CF_TOKEN "Cloudflare API 令牌" \
    "在 dash.cloudflare.com → 右上头像 → 我的个人资料 → API 令牌 → 创建令牌 中创建。" \
    "" "yes"

  ask CF_ACCOUNT_ID "Cloudflare 账户 ID" \
    "在任意域名的概览页右侧 API 区域可见，是一串 32 位十六进制。" \
    ""

  ask ROOT_DOMAIN "根域名 (区域)" \
    "你已托管在 Cloudflare 的主域名，例如 example.com。脚本会据此自动查区域 ID。" \
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

  # Cloudflare 与 VPS API 通信所用的令牌。复用已安装的令牌。
  load_env
  CF_BEARER="${CFG_VALUE[SUBFLOW_API_TOKEN]:-}"
  if [[ -z "${CF_BEARER}" ]]; then
    CF_BEARER="$(generate_token)"
    CFG_VALUE[SUBFLOW_API_TOKEN]="${CF_BEARER}"
    save_env
    if is_installed; then
      reload_and_restart
    fi
    ok "未找到现有 VPS 令牌，已生成并写入数据 API 配置。"
  fi
  # 隧道转发到的本地源站（数据 API 绑定在此处）。
  ORIGIN_URL="http://${CFG_VALUE[SUBFLOW_LISTEN_HOST]:-127.0.0.1}:${CFG_VALUE[SUBFLOW_LISTEN_PORT]:-28080}"
}

confirm_inputs() {
  printf '%b\n' ""
  printf '%b\n' "  ${C_CYAN}${C_BOLD}请确认 Cloudflare 部署配置${C_RESET}"
  printf '%b\n' "    ${C_GREY}账户 ID${C_RESET}      = ${C_LAV}${CF_ACCOUNT_ID}${C_RESET}"
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

# ----- Cloudflare 操作 --------------------------------------------------------
verify_token() {
  step "校验 API 令牌…"
  local resp ok_field
  resp="$(cf_api "${CF_TOKEN}" GET "/user/tokens/verify")"
  ok_field="$(json_get "${resp}" "d.get('success')")"
  if [[ "${ok_field}" != "True" ]]; then
    err "令牌校验失败，请检查权限/有效性。"
    exit 1
  fi
  ok "令牌有效。"
}

resolve_zone() {
  step "查询区域 ID（${ROOT_DOMAIN}）…"
  local resp
  resp="$(cf_api "${CF_TOKEN}" GET "/zones?name=${ROOT_DOMAIN}")"
  ZONE_ID="$(json_get "${resp}" "d['result'][0]['id'] if d.get('result') else ''")"
  if [[ -z "${ZONE_ID}" ]]; then
    err "未找到区域：${ROOT_DOMAIN}。请确认该域名已托管在此 Cloudflare 账户。"
    exit 1
  fi
  ok "区域 ID: ${ZONE_ID}"
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
  step "通过 Wrangler 直接上传 Pages 资源（functions/）…"
  # 将 Wrangler 的配置目录隔离到临时位置。预先存在的 ~/.config/.wrangler
  #（例如之前使用 Wrangler 时遗留的 OAuth 登录）可能优先于 CLOUDFLARE_API_TOKEN，
  # 即使令牌本身有效也会导致身份验证代码 10001。干净的 XDG_CONFIG_HOME 会强制
  # Wrangler 回退到传入的环境变量令牌。同时移除所有旧版
  # CLOUDFLARE_API_KEY/EMAIL，以免它们遮蔽该令牌。
  local cfg_home rc=0
  verify_wrangler_package || exit 1
  cfg_home="$(mktemp -d)"
  ( cd "${PAGES_DIR}" && \
    env -u CLOUDFLARE_API_KEY -u CLOUDFLARE_EMAIL \
      CLOUDFLARE_API_TOKEN="${CF_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" \
      XDG_CONFIG_HOME="${cfg_home}" \
      npx --yes "wrangler@${WRANGLER_VERSION}" pages deploy \
        --project-name "${PROJECT_NAME}" \
        --branch main \
        --commit-dirty=true ) || rc=$?
  rm -rf "${cfg_home}"
  if [[ "${rc}" -ne 0 ]]; then
    err "Pages 资源上传失败（wrangler 退出码 ${rc}）。请确认令牌含 Cloudflare Pages → 编辑权限后重跑 sf deploy。"
    exit 1
  fi
  ok "部署完成。"
}

set_secrets() {
  step "写入 Pages 机密（VPS_API_BASE_URL / VPS_API_BEARER_TOKEN）…"
  # 通过 REST API 设置机密，而不使用 `wrangler pages secret put`。
  # REST 路径使用已在此处完成身份验证的同一 Bearer 令牌，避免 Wrangler 的
  # 凭据解析异常（身份验证代码 10001）。这些值会写为加密的项目级生产环境变量，
  # 后续部署会继承它们。缺少机密会使线上站点返回 500（“服务不可用”），
  # 因此显示警告，而不是直接失败。
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
    warn "机密写入可能失败：$(json_get "${resp}" "d.get('errors')")。若站点返回服务不可用，请检查令牌权限后重跑 sf deploy。"
  fi
}

# ----- Cloudflare Tunnel（无需开放端口即可公开本地主机 API）-------------------
# 数据 API 仅绑定到 127.0.0.1。VPS 很可能已将 :443 用于 sing-box 节点，
# 因此不能使用反向代理。cloudflared 会向外连接 Cloudflare，所以不会开放
# 任何入站端口，也不会影响节点的 :443。

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    if cloudflared --version 2>/dev/null | grep -Fq "${CLOUDFLARED_VERSION}"; then
      ok "cloudflared ${CLOUDFLARED_VERSION} 已安装。"
      return 0
    fi
    warn "检测到其他版本的 cloudflared，将替换为项目锁定版本 ${CLOUDFLARED_VERSION}。"
  fi
  step "安装 cloudflared…"
  local arch asset_arch expected_sha actual_sha download_url tmp_file staged_file
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    armv7l|armhf) asset_arch="arm" ;;
    *) asset_arch="" ;;
  esac
  if [[ -z "${asset_arch}" ]]; then
    err "未知 CPU 架构 ${arch}，请手动安装 cloudflared 后重试。"
    exit 1
  fi

  expected_sha="${CLOUDFLARED_SHA256[$asset_arch]}"
  download_url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${asset_arch}"
  tmp_file="$(mktemp /tmp/cloudflared.XXXXXX)" || {
    err "无法创建 cloudflared 临时文件。"
    exit 1
  }
  if ! curl -fsSL --retry 3 "${download_url}" -o "${tmp_file}" 2>/dev/null; then
    rm -f "${tmp_file}"
    err "cloudflared ${CLOUDFLARED_VERSION} 下载失败，请检查 VPS 网络后重试。"
    exit 1
  fi

  actual_sha="$(sha256sum "${tmp_file}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    rm -f "${tmp_file}"
    err "cloudflared SHA256 校验失败，已停止安装。"
    exit 1
  fi

  chmod 755 "${tmp_file}"
  if ! "${tmp_file}" --version 2>/dev/null | grep -Fq "${CLOUDFLARED_VERSION}"; then
    rm -f "${tmp_file}"
    err "cloudflared 二进制无法运行或版本信息不匹配。"
    exit 1
  fi

  mkdir -p /usr/local/bin
  staged_file="/usr/local/bin/.cloudflared.$$"
  if ! install -m 755 "${tmp_file}" "${staged_file}"; then
    rm -f "${tmp_file}" "${staged_file}"
    err "无法暂存 cloudflared 到 /usr/local/bin。"
    exit 1
  fi
  rm -f "${tmp_file}"
  mv -f "${staged_file}" /usr/local/bin/cloudflared
  hash -r 2>/dev/null || true

  if ! /usr/local/bin/cloudflared --version 2>/dev/null | grep -Fq "${CLOUDFLARED_VERSION}"; then
    err "cloudflared 安装后验证失败。"
    exit 1
  fi
  ok "cloudflared ${CLOUDFLARED_VERSION} 安装完成。"
}

ensure_tunnel() {
  step "创建/复用 Cloudflare Tunnel（${PROJECT_NAME}）…"
  # 如果存在同名且未删除的隧道，则复用它。
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
    err "创建 Tunnel 失败：$(json_get "${resp}" "d.get('errors')")（请确认令牌含账户 → Cloudflare Tunnel → 编辑权限）。"
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

write_tunnel_token_file() {
  local token="$1" tmp_file
  mkdir -p "${ENV_DIR}"
  chmod 700 "${ENV_DIR}"
  tmp_file="$(mktemp "${SUBFLOW_CLOUDFLARED_TOKEN_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "${token}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi
  chmod 600 "${tmp_file}"
  mv -f "${tmp_file}" "${SUBFLOW_CLOUDFLARED_TOKEN_FILE}"
  chmod 600 "${SUBFLOW_CLOUDFLARED_TOKEN_FILE}"
}

detect_deploy_init_system() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    printf 'systemd'
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    printf 'openrc'
  else
    printf 'unknown'
  fi
}

install_tunnel_systemd_service() {
  local cloudflared_bin="$1"
  cat > "${SUBFLOW_CLOUDFLARED_SYSTEMD_UNIT}" <<EOF_UNIT
[Unit]
Description=subflow Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${cloudflared_bin} tunnel run --token-file ${SUBFLOW_CLOUDFLARED_TOKEN_FILE}
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF_UNIT
  chmod 644 "${SUBFLOW_CLOUDFLARED_SYSTEMD_UNIT}"
  systemctl daemon-reload
  systemctl enable "${SUBFLOW_CLOUDFLARED_SERVICE}" >/dev/null 2>&1
  systemctl restart "${SUBFLOW_CLOUDFLARED_SERVICE}"
  systemctl is-active --quiet "${SUBFLOW_CLOUDFLARED_SERVICE}"
}

install_tunnel_openrc_service() {
  local cloudflared_bin="$1"
  cat > "${SUBFLOW_CLOUDFLARED_OPENRC_SERVICE}" <<EOF_OPENRC
#!/sbin/openrc-run
description="subflow Cloudflare Tunnel"
command="${cloudflared_bin}"
command_args="tunnel run --token-file ${SUBFLOW_CLOUDFLARED_TOKEN_FILE}"
command_background=true
pidfile="/run/${SUBFLOW_CLOUDFLARED_SERVICE}.pid"

depend() {
  need net
  after firewall
}
EOF_OPENRC
  chmod 755 "${SUBFLOW_CLOUDFLARED_OPENRC_SERVICE}"
  rc-update add "${SUBFLOW_CLOUDFLARED_SERVICE}" default >/dev/null 2>&1 || true
  if rc-service "${SUBFLOW_CLOUDFLARED_SERVICE}" status >/dev/null 2>&1; then
    rc-service "${SUBFLOW_CLOUDFLARED_SERVICE}" restart
  else
    rc-service "${SUBFLOW_CLOUDFLARED_SERVICE}" start
  fi
  rc-service "${SUBFLOW_CLOUDFLARED_SERVICE}" status >/dev/null 2>&1
}

install_tunnel_service() {
  step "安装并启动 subflow 专属 cloudflared 服务…"
  local resp token init_system cloudflared_bin
  resp="$(cf_api "${CF_TOKEN}" GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")"
  token="$(json_get "${resp}" "d.get('result','')")"
  if [[ -z "${token}" ]]; then
    err "获取 Tunnel 运行令牌失败：$(json_get "${resp}" "d.get('errors')")。"
    exit 1
  fi

  if ! write_tunnel_token_file "${token}"; then
    err "Tunnel 令牌写入失败。"
    exit 1
  fi
  unset token

  cloudflared_bin="$(command -v cloudflared 2>/dev/null || true)"
  if [[ -z "${cloudflared_bin}" ]]; then
    err "未找到 cloudflared 可执行文件。"
    exit 1
  fi
  init_system="$(detect_deploy_init_system)"
  case "${init_system}" in
    systemd)
      install_tunnel_systemd_service "${cloudflared_bin}" || {
        err "subflow-cloudflared systemd 服务启动失败。"
        exit 1
      }
      ;;
    openrc)
      install_tunnel_openrc_service "${cloudflared_bin}" || {
        err "subflow-cloudflared OpenRC 服务启动失败。"
        exit 1
      }
      ;;
    *)
      err "未识别 init 系统（需要 systemd 或 OpenRC），无法安装 Tunnel 服务。"
      exit 1
      ;;
  esac
  ok "${SUBFLOW_CLOUDFLARED_SERVICE} 已运行（仅出站连接，未开放任何入站端口）。"
}

ensure_managed_cname() {
  local record_name="$1" target="$2" label="$3"
  local encoded_name query_response query_ok count record_id existing_type existing_target
  local normalized_target body response

  encoded_name="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${record_name}")"
  query_response="$(cf_api "${CF_TOKEN}" GET "/zones/${ZONE_ID}/dns_records?name=${encoded_name}")"
  query_ok="$(json_get "${query_response}" "d.get('success')")"
  if [[ "${query_ok}" != "True" ]]; then
    err "查询 ${label} DNS 记录失败：$(json_get "${query_response}" "d.get('errors')")。"
    return 1
  fi

  count="$(json_get "${query_response}" "len(d.get('result') or [])")"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  if (( count > 1 )); then
    err "${record_name} 存在多条同名 DNS 记录，拒绝覆盖，请先在控制面板清理冲突。"
    return 1
  fi

  record_id="$(json_get "${query_response}" "d['result'][0].get('id','') if d.get('result') else ''")"
  existing_type="$(json_get "${query_response}" "d['result'][0].get('type','') if d.get('result') else ''")"
  existing_target="$(json_get "${query_response}" "d['result'][0].get('content','') if d.get('result') else ''")"
  existing_target="${existing_target,,}"
  existing_target="${existing_target%.}"
  normalized_target="${target,,}"
  normalized_target="${normalized_target%.}"

  if [[ -n "${record_id}" ]] && \
     { [[ "${existing_type}" != "CNAME" ]] || [[ "${existing_target}" != "${normalized_target}" ]]; }; then
    err "${record_name} 已存在 ${existing_type:-未知类型} 记录，目标为 ${existing_target:-空}；拒绝覆盖为 ${target}。"
    return 1
  fi

  body="$(python3 -c 'import json,sys; print(json.dumps({"type":"CNAME","name":sys.argv[1],"content":sys.argv[2],"proxied":True,"ttl":1}))' "${record_name}" "${target}")"
  if [[ -n "${record_id}" ]]; then
    response="$(cf_api "${CF_TOKEN}" PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "${body}")"
  else
    response="$(cf_api "${CF_TOKEN}" POST "/zones/${ZONE_ID}/dns_records" "${body}")"
  fi
  if [[ "$(json_get "${response}" "d.get('success')")" != "True" ]]; then
    err "设置 ${label} DNS 记录失败：$(json_get "${response}" "d.get('errors')")。"
    return 1
  fi
  ok "${label} DNS 就绪（${record_name} → ${target}）。"
}

ensure_dns_api() {
  step "创建/更新 DNS：${API_HOST} → Tunnel（CNAME，橙云）…"
  # 将 API 主机指向隧道。必须启用橙云（代理），Cloudflare 才能终止 TLS
  # 并通过隧道路由。
  local target
  target="${TUNNEL_ID}.cfargotunnel.com"
  ensure_managed_cname "${API_HOST}" "${target}" "API" || exit 1
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
  # 绑定自定义域不会创建用于验证的 DNS 记录，因此域名会保持“待处理”状态。
  # 创建或更新代理 CNAME SUB_HOST -> *.pages.dev，以自动完成验证。
  if [[ -z "${PROJECT_SUBDOMAIN:-}" ]]; then
    warn "未取得 Pages 子域，跳过订阅域 CNAME；请在面板手动添加 ${SUB_HOST} → <项目>.pages.dev。"
    return 0
  fi
  step "创建/更新 DNS：${SUB_HOST} → ${PROJECT_SUBDOMAIN}（CNAME，橙云）…"
  ensure_managed_cname "${SUB_HOST}" "${PROJECT_SUBDOMAIN}" "订阅域" || exit 1
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
  require_python3
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
  # 机密必须在使用它们的部署之前存在，否则线上站点会返回 500“服务不可用”，
  # 直至下一次部署。
  set_secrets
  deploy_assets
  # 通过 Cloudflare Tunnel 公开本地主机 API（无入站端口）。
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
