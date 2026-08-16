import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SHARED_UI = REPO_ROOT / "vps" / "shared" / "ui.sh"
DEPLOY_LIB = REPO_ROOT / "vps" / "deploy" / "lib.sh"


class ShellUiTests(unittest.TestCase):
  def test_deploy_scripts_use_one_shared_theme_source(self):
    self.assertTrue(SHARED_UI.is_file())
    shared = SHARED_UI.read_text(encoding="utf-8")
    deploy = DEPLOY_LIB.read_text(encoding="utf-8")

    for symbol in ("setup_colors()", "ok()", "warn()", "banner()"):
      self.assertIn(symbol, shared)
      self.assertNotIn(symbol, deploy)
    self.assertIn('source "${_UI_FILE}"', deploy)
    self.assertIn('cp "${SOURCE_ROOT}/vps/shared/ui.sh" "${CLI_ROOT}/ui.sh"', deploy)

  def test_no_color_output_contains_no_escape_sequences(self):
    command = """
      NO_COLOR=1
      AUTHOR=Arno
      REPO_URL=https://example.com/subflow
      source vps/shared/ui.sh
      ok '操作成功'
      warn '风险提示'
      banner
    """
    result = subprocess.run(
      ["bash", "-c", command],
      cwd=REPO_ROOT,
      check=True,
      capture_output=True,
      text=True,
      encoding="utf-8",
    )
    output = result.stdout + result.stderr
    self.assertNotIn("\x1b", output)
    self.assertIn("操作成功", output)
    self.assertIn("风险提示", output)
    self.assertIn("SUBFLOW", output)


if __name__ == "__main__":
  unittest.main()