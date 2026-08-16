import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from check_markdown_links import find_broken_links


class MarkdownLinkTests(unittest.TestCase):
  def test_only_missing_and_outside_local_targets_are_reported(self):
    with tempfile.TemporaryDirectory() as temp_dir:
      root = Path(temp_dir)
      docs = root / "docs"
      docs.mkdir()
      (root / "README.md").write_text("# 首页\n", encoding="utf-8")
      guide = docs / "guide.md"
      guide.write_text(
        "\n".join((
          "[存在](../README.md)",
          "[外部](https://example.com/file.md)",
          "[章节](#section)",
          "[缺失](missing.md)",
          "[越界](../../outside.md)",
        )),
        encoding="utf-8",
      )

      errors = find_broken_links([guide], root)

      self.assertEqual(len(errors), 2)
      self.assertTrue(any("目标不存在: missing.md" in error for error in errors))
      self.assertTrue(any("链接越出仓库: ../../outside.md" in error for error in errors))


if __name__ == "__main__":
  unittest.main()