import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "vps"))

from subflow.config import AppConfig
from subflow.http.handlers import RequestHandler


class HttpHandlerTests(unittest.TestCase):
  def setUp(self):
    self.temp_dir = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp_dir.cleanup)
    root = Path(self.temp_dir.name)
    self.config_path = root / "config.json"
    self.user_db_path = root / "users.json"
    self.meta_path = root / "meta.json"
    self.index_path = root / "subscriptions.json"

    self.config_path.write_text(json.dumps({
      "inbounds": [
        {
          "type": "vless",
          "tag": "reality-443",
          "listen": "::",
          "listen_port": 443,
          "users": [
            {"name": "tokyo@alice", "uuid": "alice-uuid", "flow": "xtls-rprx-vision"},
            {"name": "tokyo@bob", "uuid": "bob-uuid"},
          ],
          "tls": {
            "server_name": "www.example.com",
            "reality": {
              "enabled": True,
              "private_key": "REALITY_PRIVATE_KEY",
              "short_id": ["abcd1234"],
            },
          },
        },
      ],
    }), encoding="utf-8")
    self.user_db_path.write_text(json.dumps({
      "users": {
        "alice": {
          "enabled": True,
          "quota_gb": 100,
          "used_up_bytes": 10,
          "used_down_bytes": 20,
          "expire_at": "0",
        },
        "disabled": {"enabled": False},
      },
    }), encoding="utf-8")
    self.meta_path.write_text(json.dumps({
      "reality-443": {
        "public_key": "REALITY_PUBLIC_KEY",
        "private_key": "META_PRIVATE_KEY",
      },
    }), encoding="utf-8")

    RequestHandler.config = AppConfig(
      listen_host="127.0.0.1",
      listen_port=0,
      api_token="test-token",
      config_json_path=self.config_path,
      user_db_path=self.user_db_path,
      meta_json_path=self.meta_path,
      public_ip="203.0.113.10",
      vless_ws_domain="vless.example.com",
      vmess_ws_domain="vmess.example.com",
      include_disabled_users=False,
      subscription_index_path=self.index_path,
    )
    self.server = ThreadingHTTPServer(("127.0.0.1", 0), RequestHandler)
    self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
    self.thread.start()
    self.addCleanup(self._stop_server)

  def _stop_server(self):
    self.server.shutdown()
    self.server.server_close()
    self.thread.join(timeout=2)

  def _request(self, path: str, authorized: bool = True):
    host, port = self.server.server_address
    request = urllib.request.Request(f"http://{host}:{port}{path}")
    if authorized:
      request.add_header("Authorization", "Bearer test-token")
    try:
      with urllib.request.urlopen(request, timeout=2) as response:
        return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
      try:
        return error.code, dict(error.headers), error.read()
      finally:
        error.close()

  def test_all_routes_require_bearer_token(self):
    for path in ("/healthz", "/internal/raw/alice"):
      with self.subTest(path=path):
        status, _, body = self._request(path, authorized=False)
        self.assertEqual(status, 403)
        self.assertEqual(body, "禁止访问".encode("utf-8"))

  def test_health_response_uses_chinese_text(self):
    status, headers, body = self._request("/healthz")

    self.assertEqual(status, 200)
    self.assertEqual(headers.get("Cache-Control"), "no-store")
    self.assertEqual(body, "正常".encode("utf-8"))

  def test_user_payload_is_private_and_not_cached(self):
    status, headers, body = self._request("/internal/raw/alice")

    self.assertEqual(status, 200)
    self.assertEqual(headers.get("Cache-Control"), "no-store")
    payload = json.loads(body)
    self.assertEqual(payload["schema_version"], 1)
    self.assertEqual(payload["username"], "alice")
    self.assertEqual(payload["inbounds"][0]["users"], [
      {"name": "tokyo@alice", "uuid": "alice-uuid", "flow": "xtls-rprx-vision"},
    ])
    serialized = json.dumps(payload)
    self.assertNotIn("REALITY_PRIVATE_KEY", serialized)
    self.assertNotIn("META_PRIVATE_KEY", serialized)
    self.assertNotIn("bob-uuid", serialized)

  def test_unknown_and_disabled_users_return_not_found(self):
    for username in ("unknown", "disabled"):
      with self.subTest(username=username):
        status, headers, body = self._request(f"/internal/raw/{username}")
        self.assertEqual(status, 404)
        self.assertEqual(headers.get("Cache-Control"), "no-store")
        self.assertEqual(body, "未找到".encode("utf-8"))

  def test_valid_index_is_used_without_legacy_source_files(self):
    self.index_path.write_text(json.dumps({
      "schema_version": 1,
      "users": {
        "alice": {
          "usage": {
            "enabled": True,
            "quota_gb": 200,
            "used_up_bytes": 30,
            "used_down_bytes": 40,
          },
          "inbounds": [
            {
              "type": "vless",
              "tag": "reality-8443",
              "listen": "::",
              "listen_port": 8443,
              "users": [
                {"name": "indexed@alice", "uuid": "indexed-uuid"},
                {"name": "indexed@bob", "uuid": "bob-indexed-uuid"},
              ],
              "tls": {
                "server_name": "indexed.example.com",
                "reality": {
                  "enabled": True,
                  "private_key": "INDEX_PRIVATE_KEY",
                  "short_id": ["11223344"],
                },
              },
            },
          ],
          "meta": {
            "reality-8443": {
              "public_key": "INDEX_PUBLIC_KEY",
              "private_key": "INDEX_META_PRIVATE_KEY",
            },
          },
        },
      },
    }), encoding="utf-8")
    self.config_path.unlink()
    self.user_db_path.unlink()
    self.meta_path.unlink()

    status, _, body = self._request("/internal/raw/alice")

    self.assertEqual(status, 200)
    payload = json.loads(body)
    self.assertEqual(payload["usage"]["quota_gb"], 200)
    self.assertEqual(payload["inbounds"][0]["users"], [
      {"name": "indexed@alice", "uuid": "indexed-uuid"},
    ])
    serialized = json.dumps(payload)
    self.assertNotIn("INDEX_PRIVATE_KEY", serialized)
    self.assertNotIn("INDEX_META_PRIVATE_KEY", serialized)
    self.assertNotIn("bob-indexed-uuid", serialized)

  def test_invalid_index_fails_closed(self):
    self.index_path.write_text(json.dumps({
      "schema_version": 2,
      "users": {},
    }), encoding="utf-8")

    status, headers, body = self._request("/internal/raw/alice")

    self.assertEqual(status, 500)
    self.assertEqual(headers.get("Cache-Control"), "no-store")
    self.assertEqual(body, "服务暂时不可用".encode("utf-8"))

  def test_existing_index_never_falls_back_for_unknown_user(self):
    self.index_path.write_text(json.dumps({
      "schema_version": 1,
      "users": {},
    }), encoding="utf-8")

    status, _, body = self._request("/internal/raw/alice")

    self.assertEqual(status, 404)
    self.assertEqual(body, "未找到".encode("utf-8"))


if __name__ == "__main__":
  unittest.main()