import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEPENDENCY_LOCK = REPO_ROOT / "configs" / "dependencies.lock.json"
SINGBOX_DEPENDENCIES = REPO_ROOT / "vps" / "singbox" / "lib" / "00_dependencies.sh"
V2RAY_API = REPO_ROOT / "vps" / "singbox" / "lib" / "50_v2ray_api.sh"


class RuntimeDependencyTests(unittest.TestCase):
  def test_grpcurl_is_locked_and_mandatorily_verified(self):
    dependency_lock = json.loads(DEPENDENCY_LOCK.read_text(encoding="utf-8"))
    generated = SINGBOX_DEPENDENCIES.read_text(encoding="utf-8")
    installer = V2RAY_API.read_text(encoding="utf-8")

    self.assertEqual(dependency_lock["grpcurl"]["version"], "1.9.3")
    self.assertIn('GRPCURL_VERSION="1.9.3"', generated)
    self.assertIn(
      '[x86_64]="a926b62a85787ccf73ef8736b3ae554f1242e39d92bb8767a79d6dd23b11d1d5"',
      generated,
    )
    self.assertIn(
      '[arm64]="b20a00c1cb82ab81ec32696766d4076e99b4cb5ca0823a71767ba64dbea0f263"',
      generated,
    )
    self.assertNotIn("releases/latest", installer)
    self.assertNotIn("跳过完整性校验", installer)
    self.assertIn('actual_sha="$(sha256sum', installer)
    self.assertIn('"${actual_sha}" != "${expected_sha}"', installer)
    self.assertIn('"$GRPCURL_BIN" -version', installer)


if __name__ == "__main__":
  unittest.main()