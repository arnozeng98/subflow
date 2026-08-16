subflow_detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      printf '%s\n' "amd64"
      ;;
    aarch64|arm64)
      printf '%s\n' "arm64"
      ;;
    *)
      subflow_fail "不支持的平台架构: ${machine}"
      return 1
      ;;
  esac
}

subflow_detect_init() {
  if subflow_has_cmd systemctl && [[ -d /run/systemd/system || -n "${INVOCATION_ID:-}" ]]; then
    printf '%s\n' "systemd"
    return 0
  fi
  if subflow_has_cmd rc-service || [[ -d /run/openrc ]]; then
    printf '%s\n' "openrc"
    return 0
  fi
  subflow_fail "不支持的 init 系统"
  return 1
}

subflow_detect_pkg_manager() {
  local candidate
  for candidate in apt-get dnf yum pacman apk zypper; do
    if subflow_has_cmd "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  subflow_fail "不支持的软件包管理器"
  return 1
}

subflow_detect_platform() {
  local pkg init arch
  pkg="$(subflow_detect_pkg_manager)" || return 1
  init="$(subflow_detect_init)" || return 1
  arch="$(subflow_detect_arch)" || return 1
  printf '%s|%s|%s\n' "$pkg" "$init" "$arch"
}
