import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "vps"))

from subflow.config import AppConfig
from subflow.data_sources.subscription_index import (
  SubscriptionIndexStatus,
  lookup_subscription,
)


class SubscriptionIndexTests(unittest.TestCase):
  def setUp(self):
    self.temp_dir = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp_dir.cleanup)
    root = Path(self.temp_dir.name)
    self.index_path = root / "subscriptions.json"
    self.config = AppConfig(
      listen_host="127.0.0.1",
      listen_port=28080,
      api_token="test-token",
      config_json_path=root / "config.json",
      user_db_path=root / "users.json",
      meta_json_path=root / "meta.json",
      public_ip="203.0.113.10",
      vless_ws_domain="vless.example.com",
      vmess_ws_domain="vmess.example.com",
      include_disabled_users=False,
      subscription_index_path=self.index_path,
    )

  def _write_index(self, payload):
    self.index_path.write_text(json.dumps(payload), encoding="utf-8")

  def test_missing_index_is_an_explicit_compatibility_state(self):
    result = lookup_subscription(self.config, "alice")

    self.assertEqual(result.status, SubscriptionIndexStatus.MISSING)
    self.assertIsNone(result.record)

  def test_invalid_or_incompatible_index_fails_closed(self):
    invalid_payloads = (
      [],
      {},
      {"schema_version": 2, "users": {}},
      {"schema_version": 1, "users": []},
    )
    for payload in invalid_payloads:
      with self.subTest(payload=payload):
        self._write_index(payload)
        result = lookup_subscription(self.config, "alice")
        self.assertEqual(result.status, SubscriptionIndexStatus.INVALID)
        self.assertIsNone(result.record)

  def test_non_file_index_path_fails_closed(self):
    self.index_path.mkdir()

    result = lookup_subscription(self.config, "alice")

    self.assertEqual(result.status, SubscriptionIndexStatus.INVALID)

  def test_index_stat_error_fails_closed(self):
    with patch.object(Path, "stat", side_effect=PermissionError("denied")):
      result = lookup_subscription(self.config, "alice")

    self.assertEqual(result.status, SubscriptionIndexStatus.INVALID)

  def test_unknown_user_is_distinct_from_invalid_index(self):
    self._write_index({"schema_version": 1, "users": {}})

    result = lookup_subscription(self.config, "alice")

    self.assertEqual(result.status, SubscriptionIndexStatus.NOT_FOUND)
    self.assertIsNone(result.record)

  def test_valid_user_record_is_returned(self):
    record = {
      "usage": {"enabled": True, "quota_gb": 100},
      "inbounds": [{"type": "vless", "tag": "reality-443", "users": []}],
      "meta": {"reality-443": {"public_key": "public-key"}},
    }
    self._write_index({
      "schema_version": 1,
      "users": {"alice": record},
    })

    result = lookup_subscription(self.config, "alice")

    self.assertEqual(result.status, SubscriptionIndexStatus.FOUND)
    self.assertEqual(result.record, record)


if __name__ == "__main__":
  unittest.main()