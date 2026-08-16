#!/usr/bin/env bash
# ============================================================
# build.sh — 将 lib/*.sh 模块合并为单体 sb.sh 用于分发
# 用法: bash build.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
OUT="${SCRIPT_DIR}/sb.sh"

if [ ! -d "$LIB_DIR" ]; then
  echo "[ERR] 未找到 lib/ 目录: $LIB_DIR"
  exit 1
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

run_generator() {
  local script_path="$1" label="$2" generated=0
  [ -f "$script_path" ] || return 0
  if command -v python3 >/dev/null 2>&1 && python3 "$script_path" >/dev/null 2>&1; then
    generated=1
  elif command -v python >/dev/null 2>&1 && python "$script_path" >/dev/null 2>&1; then
    generated=1
  fi
  [ "$generated" -eq 1 ] || echo "[WARN] ${label} 失败，沿用已提交的生成文件"
}

# 重新生成共享配置与依赖常量；生成工具不可用时沿用已提交文件。
run_generator "${REPO_ROOT}/scripts/gen_config.py" "gen_config"
run_generator "${REPO_ROOT}/scripts/gen_dependencies.py" "gen_dependencies"

{
  echo '#!/usr/bin/env bash'
  echo ''
  echo '# ============================================================'
  echo '# Sing-box Elite Management System'
  echo '# 由 build.sh 自动合并生成，请勿直接编辑此文件'
  echo '# 源码位于 lib/ 目录下的各模块文件'
  echo '# ============================================================'
  echo ''

  for f in "$LIB_DIR"/[0-9]*.sh; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    echo ""
    echo "# >>>>>>>>> BEGIN MODULE: $fname <<<<<<<<<<<"
    # 跳过 shebang 行，保留其余全部内容
    tail -n +2 "$f" | sed 's/\r$//'
    echo ""
    echo "# >>>>>>>>> END MODULE: $fname <<<<<<<<<<<"
  done
} > "$OUT"

chmod +x "$OUT"

lines="$(wc -l < "$OUT")"

echo "[OK] 构建完成: $OUT"
echo "     行数: $lines"
