import hashlib
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = REPO_ROOT / "vps" / "singbox" / "build.sh"
GENERATED_SCRIPT = REPO_ROOT / "vps" / "singbox" / "sb.sh"


class SingboxBuildTests(unittest.TestCase):
  def test_build_is_deterministic(self):
    first = self._build_and_hash()
    second = self._build_and_hash()

    self.assertEqual(first, second)
    generated = GENERATED_SCRIPT.read_text(encoding="utf-8")
    self.assertNotIn("构建时间:", generated)

  def _build_and_hash(self):
    subprocess.run(
      ["bash", str(BUILD_SCRIPT)],
      cwd=REPO_ROOT,
      check=True,
      stdout=subprocess.DEVNULL,
    )
    return hashlib.sha256(GENERATED_SCRIPT.read_bytes()).hexdigest()


if __name__ == "__main__":
  unittest.main()