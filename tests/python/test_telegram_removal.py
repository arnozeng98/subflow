import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SINGBOX_ROOT = REPO_ROOT / "vps" / "singbox"
DEPLOY_LIB = REPO_ROOT / "vps" / "deploy" / "lib.sh"


class TelegramRemovalTests(unittest.TestCase):
  def test_telegram_source_modules_are_removed(self):
    self.assertFalse((SINGBOX_ROOT / "lib" / "63_telegram_bot.sh").exists())
    self.assertFalse((SINGBOX_ROOT / "lib" / "tg-center-bot.py").exists())

  def test_generated_manager_has_no_telegram_feature(self):
    generated = (SINGBOX_ROOT / "sb.sh").read_text(encoding="utf-8")

    self.assertNotIn("Telegram Bot 管理", generated)
    self.assertNotIn("telegram_bot_manager_menu", generated)
    self.assertNotIn("api.telegram.org", generated)
    self.assertIn('"--tg-agent-sync"', generated)

  def test_deploy_migration_cleans_legacy_runtime(self):
    script = DEPLOY_LIB.read_text(encoding="utf-8")

    self.assertIn("cleanup_legacy_telegram_runtime", script)
    self.assertIn("sb-tg-bot", script)
    self.assertIn("--tg-agent-sync", script)
    self.assertIn("telegram.json", script)
    self.assertIn(".disabled", script)
    self.assertIn("tg-center-bot.py", script)


if __name__ == "__main__":
  unittest.main()