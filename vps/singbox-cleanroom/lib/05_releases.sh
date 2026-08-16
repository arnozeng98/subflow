subflow_release_normalize_version() {
  local version="${1#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    subflow_fail "版本号不合法: ${1}"
    return 1
  fi
  printf '%s\n' "$version"
}

subflow_release_manifest_validate() {
  if ! subflow_release_manifest | jq -e '
    .latest as $latest
    | type == "object"
    and .schema_version == 1
    and (.repository | type == "string")
    and (.latest | type == "string")
    and (.releases | type == "object")
    and (.releases[$latest] | type == "object")
  ' >/dev/null; then
    subflow_fail "sing-box 批准清单无效"
    return 1
  fi
}

subflow_release_latest() {
  local version
  subflow_release_manifest_validate || return 1
  version="$(subflow_release_manifest | jq -er '.latest')" || return 1
  subflow_release_normalize_version "$version"
}

subflow_release_repository() {
  local repository
  subflow_release_manifest_validate || return 1
  repository="$(subflow_release_manifest | jq -er '.repository')" || return 1
  if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    subflow_fail "批准清单中的仓库名不合法"
    return 1
  fi
  printf '%s\n' "$repository"
}

subflow_release_asset_field() {
  local version arch field value
  version="$(subflow_release_normalize_version "$1")" || return 1
  arch="$2"
  field="$3"
  case "$arch" in
    amd64|arm64) ;;
    *)
      subflow_fail "不支持的发布架构: ${arch}"
      return 1
      ;;
  esac
  case "$field" in
    name|sha256) ;;
    *) return 1 ;;
  esac

  subflow_release_manifest_validate || return 1
  value="$(subflow_release_manifest | jq -er \
    --arg version "$version" \
    --arg arch "$arch" \
    --arg field "$field" \
    '.releases[$version].assets[$arch][$field] // empty')" || {
      subflow_fail "版本未获批准: ${version}/${arch}"
      return 1
    }

  if [[ "$field" == "name" && ! "$value" =~ ^sing-box-linux-(amd64|arm64)$ ]]; then
    subflow_fail "批准清单中的资产名不合法"
    return 1
  fi
  if [[ "$field" == "sha256" && ! "$value" =~ ^[0-9a-f]{64}$ ]]; then
    subflow_fail "批准清单中的 SHA256 不合法"
    return 1
  fi
  printf '%s\n' "$value"
}

subflow_release_asset_name() {
  subflow_release_asset_field "$1" "$2" name
}

subflow_release_sha256() {
  subflow_release_asset_field "$1" "$2" sha256
}

subflow_release_url() {
  local version="$1" arch="$2" repository asset base_url
  version="$(subflow_release_normalize_version "$version")" || return 1
  repository="$(subflow_release_repository)" || return 1
  asset="$(subflow_release_asset_name "$version" "$arch")" || return 1
  base_url="${SUBFLOW_RELEASE_BASE_URL:-https://github.com/${repository}/releases/download}"
  printf '%s/v%s/%s\n' "${base_url%/}" "$version" "$asset"
}