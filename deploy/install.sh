#!/bin/sh
# Only bootstrap the verified native installer. Existing data is never removed.
set -eu
case "$(uname -s)" in Linux) ;; *) echo "subflow requires Linux" >&2; exit 1;; esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "Supported architectures: amd64, arm64" >&2; exit 1 ;;
esac
version="${SUBFLOW_VERSION:-latest}"
case "$version" in *[!a-zA-Z0-9._-]*|'') echo "Invalid SUBFLOW_VERSION" >&2; exit 1;; esac
case "$version" in latest|subflow-v*) ;; *) echo "Use an application tag subflow-v*" >&2; exit 1;; esac

yes=0
for arg do
  [ "$arg" != --yes ] || yes=1
done
bootstrap_dependencies() {
  set --
  command -v tar >/dev/null 2>&1 || set -- "$@" tar
  command -v gzip >/dev/null 2>&1 || set -- "$@" gzip
  command -v sha256sum >/dev/null 2>&1 || set -- "$@" coreutils
  command -v awk >/dev/null 2>&1 || set -- "$@" mawk
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    set -- "$@" curl
  fi
  [ -s /etc/ssl/certs/ca-certificates.crt ] || set -- "$@" ca-certificates
  [ "$#" -ne 0 ] || return 0
  if [ ! -r /etc/debian_version ] || ! command -v apt-get >/dev/null 2>&1 || [ "$(id -u)" != 0 ]; then
    echo "Missing bootstrap packages: $*. Install them first, or rerun as root on Debian." >&2
    return 1
  fi
  if [ "$yes" -ne 1 ]; then
    printf 'Install required bootstrap packages: %s? [y/N] ' "$*" >&2
    answer=
    IFS= read -r answer || :
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled; no packages installed." >&2; return 1;; esac
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update || {
    echo "Bootstrap dependency installation failed: apt-get update." >&2; return 1;
  }
  DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "$@" || {
    echo "Bootstrap dependency installation failed: apt-get install." >&2; return 1;
  }
}
bootstrap_dependencies
for tool in tar gzip sha256sum awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required bootstrap command still missing: $tool" >&2; exit 1; }
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Required bootstrap downloader still missing: curl or wget" >&2
  exit 1
fi

base="https://github.com/arnozeng98/subflow/releases"
if [ "$version" = latest ]; then base="$base/latest/download"; else base="$base/download/$version"; fi
asset="subflow-linux-$arch.tar.gz"
boot_parent="$(pwd -P)"
work="$boot_parent/.subflow-bootstrap.$$"
umask 077
# mkdir is exclusive: an existing directory is never adopted or cleaned.
mkdir "$work"
# Invoked indirectly by the EXIT trap; cleanup paths are covered by fixture tests.
# shellcheck disable=SC2317,SC2329
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$work" = "$boot_parent/.subflow-bootstrap.$$" ] && [ ! -L "$work" ]; then
    rm -rf -- "$work" || echo "Could not clean bootstrap directory: $work" >&2
  fi
  exit "$status"
}
trap 'cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

download() {
  url=$1
  destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl --disable --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --connect-timeout 30 --retry 2 "$url" -o "$destination"
    return
  fi
  # wget --https-only applies to recursive links, not every redirect. Follow
  # redirects ourselves so an HTTPS response cannot downgrade the next request.
  redirects=0
  while [ "$redirects" -le 10 ]; do
    case "$url" in https://*) ;; *) echo "Refusing non-HTTPS release URL." >&2; return 1;; esac
    code=0
    wget --no-config --no-hsts --max-redirect=0 --server-response --secure-protocol=TLSv1_2 \
      --timeout=30 --tries=2 -O "$destination" "$url" 2>"$work/download.headers" || code=$?
    [ "$code" -ne 0 ] || return 0
    response="$(awk '$1 ~ /^HTTP\// {code=$2} END {print code}' "$work/download.headers")"
    case "$response" in
      301|302|303|307|308)
        url="$(awk 'tolower($1) == "location:" {url=$2; sub(/\r$/, "", url)} END {print url}' "$work/download.headers")"
        redirects=$((redirects + 1))
        ;;
      *) echo "wget release download failed (exit $code)." >&2; return "$code" ;;
    esac
  done
  echo "Too many release download redirects." >&2
  return 1
}
download "$base/$asset" "$work/$asset"
download "$base/sha256sum.txt" "$work/sha256sum.txt"
awk -v name="$asset" '$2 == name || $2 == "*" name {print}' "$work/sha256sum.txt" > "$work/checksum.txt"
[ "$(awk 'END { print NR }' "$work/checksum.txt")" = 1 ] || { echo "Missing or duplicate release checksum" >&2; exit 1; }
if ! (cd "$work"; sha256sum --check --status checksum.txt); then
  echo "Release checksum verification failed; installer was not executed." >&2
  exit 1
fi
tar -xzf "$work/$asset" -C "$work"
chmod 755 "$work/subflow"
status=0
"$work/subflow" install --assets "$work" "$@" || status=$?
exit "$status"
