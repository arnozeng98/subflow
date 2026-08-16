import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "vps"))

from subflow.config import AppConfig
from subflow.services.raw_projection import build_raw_payload


class RawProjectionSecurityTests(unittest.TestCase):
  def setUp(self):
    self.temp_dir = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp_dir.cleanup)
    root = Path(self.temp_dir.name)
    self.config_path = root / "config.json"
    self.user_db_path = root / "users.json"
    self.meta_path = root / "meta.json"

    self.config_path.write_text(json.dumps({
      "inbounds": [
        {
          "type": "vless",
          "tag": "reality-443",
          "listen": "::",
          "listen_port": 443,
          "users": [
            {
              "name": "tokyo@alice",
              "uuid": "alice-uuid",
              "flow": "xtls-rprx-vision",
              "server_only_note": "do-not-export",
            },
            {"name": "tokyo@bob", "uuid": "bob-uuid"},
          ],
          "tls": {
            "enabled": True,
            "server_name": "www.example.com",
            "key": ["TLS_PRIVATE_KEY"],
            "key_path": "/etc/sing-box/private.key",
            "certificate_path": "/etc/sing-box/certificate.pem",
            "acme": {
              "domain": ["node.example.com"],
              "dns01_challenge": {
                "provider": "cloudflare",
                "api_token": "CF_API_TOKEN_SECRET",
                "zone_token": "CF_ZONE_TOKEN_SECRET",
              },
            },
            "reality": {
              "enabled": True,
              "private_key": "REALITY_PRIVATE_KEY",
              "short_id": ["abcd1234"],
              "handshake": {"server": "www.example.com", "server_port": 443},
            },
          },
        },
        {
          "type": "shadowsocks",
          "tag": "ss-8388",
          "listen": "::",
          "listen_port": 8388,
          "method": "2022-blake3-aes-128-gcm",
          "password": "SS2022_SERVER_PASSWORD",
          "users": [
            {"name": "osaka@alice", "password": "SS2022_USER_PASSWORD"},
            {"name": "osaka@bob", "password": "BOB_PASSWORD"},
          ],
        },
        {
          "type": "anytls",
          "tag": "anytls-7443",
          "listen": "::",
          "listen_port": 7443,
          "users": [
            {"name": "nagoya@alice", "password": "ANYTLS_ALICE_PASSWORD"},
            {"name": "nagoya@bob", "password": "ANYTLS_BOB_PASSWORD"},
          ],
          "tls": {
            "enabled": True,
            "server_name": "any.example.com",
            "key_path": "/etc/sing-box/anytls.key",
            "acme": {
              "domain": ["any.example.com"],
              "dns01_challenge": {
                "provider": "cloudflare",
                "api_token": "ANYTLS_CF_API_TOKEN_SECRET",
              },
            },
          },
        },
      ],
    }), encoding="utf-8")
    self.meta_path.write_text(json.dumps({
      "reality-443": {
        "public_key": "REALITY_PUBLIC_KEY",
        "private_key": "META_PRIVATE_KEY",
      },
    }), encoding="utf-8")
    self.user_db_path.write_text("{}", encoding="utf-8")

    self.config = AppConfig(
      listen_host="127.0.0.1",
      listen_port=28080,
      api_token="test-token",
      config_json_path=self.config_path,
      user_db_path=self.user_db_path,
      meta_json_path=self.meta_path,
      public_ip="203.0.113.10",
      vless_ws_domain="vless.example.com",
      vmess_ws_domain="vmess.example.com",
      include_disabled_users=False,
    )

  def test_projection_only_contains_client_required_fields(self):
    payload = build_raw_payload(self.config, "alice")

    self.assertEqual(payload["schema_version"], 1)
    self.assertEqual(payload["inbounds"], [
      {
        "type": "vless",
        "tag": "reality-443",
        "listen_port": 443,
        "users": [
          {
            "name": "tokyo@alice",
            "uuid": "alice-uuid",
            "flow": "xtls-rprx-vision",
          },
        ],
        "tls": {
          "server_name": "www.example.com",
          "reality": {
            "enabled": True,
            "short_id": ["abcd1234"],
          },
        },
      },
      {
        "type": "shadowsocks",
        "tag": "ss-8388",
        "listen_port": 8388,
        "method": "2022-blake3-aes-128-gcm",
        "password": "SS2022_SERVER_PASSWORD",
        "users": [
          {
            "name": "osaka@alice",
            "password": "SS2022_USER_PASSWORD",
          },
        ],
      },
      {
        "type": "anytls",
        "tag": "anytls-7443",
        "listen_port": 7443,
        "users": [
          {
            "name": "nagoya@alice",
            "password": "ANYTLS_ALICE_PASSWORD",
          },
        ],
        "tls": {
          "server_name": "any.example.com",
        },
      },
    ])
    self.assertEqual(payload["meta"], {
      "reality-443": {"public_key": "REALITY_PUBLIC_KEY"},
    })

    serialized = json.dumps(payload)
    for secret in (
      "REALITY_PRIVATE_KEY",
      "TLS_PRIVATE_KEY",
      "CF_API_TOKEN_SECRET",
      "CF_ZONE_TOKEN_SECRET",
      "ANYTLS_CF_API_TOKEN_SECRET",
      "ANYTLS_BOB_PASSWORD",
      "META_PRIVATE_KEY",
      "BOB_PASSWORD",
      "bob-uuid",
      "do-not-export",
    ):
      self.assertNotIn(secret, serialized)


if __name__ == "__main__":
  unittest.main()