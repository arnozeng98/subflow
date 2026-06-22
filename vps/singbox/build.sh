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

# 依据 configs/defaults.yaml 重新生成共享常量（lib/00_generated.sh），best-effort。
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if command -v python3 >/dev/null 2>&1 && [ -f "${REPO_ROOT}/scripts/gen_config.py" ]; then
  python3 "${REPO_ROOT}/scripts/gen_config.py" >/dev/null 2>&1 || echo "[WARN] gen_config 失败，沿用已提交的生成文件"
fi

{
  echo '#!/usr/bin/env bash'
  echo ''
  echo '# ============================================================'
  echo '# Sing-box Elite Management System'
  echo '# 由 build.sh 自动合并生成，请勿直接编辑此文件'
  echo '# 源码位于 lib/ 目录下的各模块文件'
  echo "# 构建时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
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

# 将抽离出来的 Telegram bot Python 源（lib/tg-center-bot.py）按标记内联回 sb.sh：
# 既保持 sb.sh 单文件可分发，又让这段 ~1300 行 Python 能作为独立 .py 编辑与 lint。
PY_SRC="${LIB_DIR}/tg-center-bot.py"
if [ -f "$PY_SRC" ]; then
  awk -v pyf="$PY_SRC" '
    /^@@INCLUDE:tg-center-bot\.py@@$/ {
      while ((getline line < pyf) > 0) print line
      close(pyf)
      next
    }
    { print }
  ' "$OUT" > "${OUT}.tmp" && mv -f "${OUT}.tmp" "$OUT"
  chmod +x "$OUT"
fi

lines="$(wc -l < "$OUT")"

echo "[OK] 构建完成: $OUT"
echo "     行数: $lines"
