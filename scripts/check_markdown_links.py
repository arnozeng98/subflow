#!/usr/bin/env python3
"""检查项目 Markdown 中的本地链接目标。"""

from pathlib import Path
import re
import sys
from typing import Iterable, List
from urllib.parse import unquote, urlsplit


REPO_ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))")


def documentation_files(repo_root: Path) -> List[Path]:
  files = [
    repo_root / "README.md",
    repo_root / "SECURITY.md",
    repo_root / "THIRD_PARTY.md",
  ]
  files.extend(sorted((repo_root / "docs").glob("**/*.md")))
  return [path for path in files if path.is_file()]


def find_broken_links(markdown_files: Iterable[Path], repo_root: Path) -> List[str]:
  errors: List[str] = []
  root = repo_root.resolve()

  for markdown_file in markdown_files:
    text = markdown_file.read_text(encoding="utf-8")
    for match in MARKDOWN_LINK.finditer(text):
      raw_target = (match.group(1) or match.group(2) or "").strip()
      if not raw_target or raw_target.startswith("#"):
        continue

      parsed = urlsplit(raw_target)
      if parsed.scheme or parsed.netloc:
        continue

      local_part = unquote(parsed.path)
      if not local_part:
        continue
      candidate = (markdown_file.parent / local_part).resolve()
      try:
        candidate.relative_to(root)
      except ValueError:
        errors.append(
          f"{markdown_file.relative_to(root)}: 链接越出仓库: {raw_target}"
        )
        continue
      if not candidate.exists():
        errors.append(
          f"{markdown_file.relative_to(root)}: 目标不存在: {raw_target}"
        )

  return errors


def main() -> int:
  errors = find_broken_links(documentation_files(REPO_ROOT), REPO_ROOT)
  if errors:
    print("\n".join(errors), file=sys.stderr)
    return 1
  print("Markdown 本地链接检查通过")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())