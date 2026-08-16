import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SH = REPO_ROOT / "vps" / "singbox-cleanroom" / "build.sh"
SB_SH = REPO_ROOT / "vps" / "singbox-cleanroom" / "sb.sh"
BASH = shutil.which("bash") or "bash"
PYTHON = Path(sys.executable)


class CleanroomAcmeTests(unittest.TestCase):
  def setUp(self):
    self.temp_dir = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp_dir.cleanup)
    self.root = Path(self.temp_dir.name)

  def _run(self, *args, env=None):
    run_env = os.environ.copy()
    run_env.setdefault("LC_ALL", "C")
    if env:
      run_env.update(env)
    return subprocess.run(
      [BASH, *args],
      cwd=REPO_ROOT,
      env=run_env,
      stdin=subprocess.DEVNULL,
      capture_output=True,
      text=True,
      check=False,
    )

  def _write_stub(self, bin_dir: Path, name: str, body: str):
    path = bin_dir / name
    path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body + "\n", encoding="utf-8")
    path.chmod(0o755)

  def _fixture(self):
    state_dir = self.root / "state"
    secrets_dir = state_dir / "secrets"
    secret_path = secrets_dir / "cloudflare-acme.json"
    data_dir = secrets_dir / "acme"
    config_path = self.root / "config.json"
    bin_dir = self.root / "bin"
    unit_path = self.root / "systemd" / "sing-box.service"
    service_state = self.root / "service.state"
    service_failed = self.root / "service.failed"
    state_dir.mkdir()
    config_path.write_text('{"inbounds":[]}\n', encoding="utf-8")
    bin_dir.mkdir()
    unit_path.parent.mkdir()
    unit_path.write_text("test service\n", encoding="utf-8")
    service_state.write_text("active\n", encoding="utf-8")
    self._write_stub(bin_dir, "flock", "exit 0")
    self._write_stub(bin_dir, "jq", "exit 0")
    self._write_stub(bin_dir, "python3", f'exec "{PYTHON.as_posix()}" "$@"')
    self._write_stub(bin_dir, "sing-box", f'''
case "${{1:-}}" in
  check)
    config="${{3:-}}"
    exec "{PYTHON.as_posix()}" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$config"
    ;;
  *) exit 0 ;;
esac
''')
    self._write_stub(bin_dir, "systemctl", '''
case "${1:-}" in
  is-active) [[ -f "${SUBFLOW_TEST_SERVICE_STATE}" ]] ;;
  restart)
    if [[ -n "${SUBFLOW_TEST_FAIL_RESTART_ONCE:-}" && ! -e "${SUBFLOW_TEST_SERVICE_FAILED}" ]]; then
      : >"${SUBFLOW_TEST_SERVICE_FAILED}"
      exit 1
    fi
    : >"${SUBFLOW_TEST_SERVICE_STATE}"
    ;;
  start) : >"${SUBFLOW_TEST_SERVICE_STATE}" ;;
  stop) rm -f "${SUBFLOW_TEST_SERVICE_STATE}" ;;
  daemon-reload|enable|disable) exit 0 ;;
  *) exit 0 ;;
esac
''')
    env = os.environ.copy()
    env.update({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "LC_ALL": "C",
      "SUBFLOW_STATE_DIR": state_dir.as_posix(),
      "SUBFLOW_SECRETS_DIR": secrets_dir.as_posix(),
      "SUBFLOW_LOCK_PATH": (self.root / "subflow.lock").as_posix(),
      "SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH": secret_path.as_posix(),
      "SUBFLOW_ACME_DATA_DIR": data_dir.as_posix(),
      "SUBFLOW_CONFIG_PATH": config_path.as_posix(),
      "SUBFLOW_INIT": "systemd",
      "SUBFLOW_SINGBOX_BIN": (bin_dir / "sing-box").as_posix(),
      "SUBFLOW_SYSTEMD_UNIT_PATH": unit_path.as_posix(),
      "SUBFLOW_TEST_SERVICE_STATE": service_state.as_posix(),
      "SUBFLOW_TEST_SERVICE_FAILED": service_failed.as_posix(),
    })
    return state_dir, secrets_dir, secret_path, data_dir, env

  def _build(self):
    result = self._run(str(BUILD_SH))
    self.assertEqual(result.returncode, 0, result.stderr)

  def test_import_status_and_clear_never_echo_tokens(self):
    self._build()
    state_dir, secrets_dir, secret_path, data_dir, env = self._fixture()
    api_token = "API_" + "A" * 36
    zone_token = "ZONE_" + "B" * 35
    api_file = self.root / "api-token"
    zone_file = self.root / "zone-token"
    api_file.write_text(api_token + "\n", encoding="ascii")
    zone_file.write_text(zone_token + "\n", encoding="ascii")

    imported = self._run(
      str(SB_SH), "acme", "import-cloudflare", api_file.as_posix(), zone_file.as_posix(), env=env,
    )

    self.assertEqual(imported.returncode, 0, imported.stderr)
    self.assertEqual(json.loads(secret_path.read_text(encoding="utf-8")), {
      "api_token": api_token,
      "zone_token": zone_token,
    })
    self.assertTrue(data_dir.is_dir())
    self.assertNotIn(api_token, imported.stdout + imported.stderr)
    self.assertNotIn(zone_token, imported.stdout + imported.stderr)

    status = self._run(str(SB_SH), "acme", "status", env=env)
    self.assertEqual(status.returncode, 0, status.stderr)
    self.assertIn("已配置", status.stdout)
    self.assertNotIn(api_token, status.stdout + status.stderr)
    self.assertNotIn(zone_token, status.stdout + status.stderr)

    refused = self._run(str(SB_SH), "acme", "clear", env=env)
    self.assertNotEqual(refused.returncode, 0)
    self.assertTrue(secret_path.exists())

    cleared = self._run(str(SB_SH), "acme", "clear", "YES", env=env)
    self.assertEqual(cleared.returncode, 0, cleared.stderr)
    self.assertFalse(secret_path.exists())
    missing = self._run(str(SB_SH), "acme", "status", env=env)
    self.assertIn("未配置", missing.stdout)

  def test_invalid_replacement_and_pending_transaction_fail_closed(self):
    self._build()
    state_dir, secrets_dir, secret_path, data_dir, env = self._fixture()
    valid_token = "VALID_" + "C" * 34
    valid_zone_token = "ZONE_" + "D" * 35
    valid_file = self.root / "valid-token"
    valid_zone_file = self.root / "valid-zone-token"
    invalid_file = self.root / "invalid-token"
    valid_file.write_text(valid_token, encoding="ascii")
    valid_zone_file.write_text(valid_zone_token, encoding="ascii")
    invalid_file.write_text("contains whitespace and is invalid\n", encoding="ascii")
    first = self._run(
      str(SB_SH), "acme", "import-cloudflare",
      valid_file.as_posix(), valid_zone_file.as_posix(), env=env,
    )
    self.assertEqual(first.returncode, 0, first.stderr)
    original = secret_path.read_bytes()

    invalid = self._run(str(SB_SH), "acme", "import-cloudflare", invalid_file.as_posix(), env=env)
    self.assertNotEqual(invalid.returncode, 0)
    self.assertEqual(secret_path.read_bytes(), original)
    self.assertNotIn(valid_token, invalid.stdout + invalid.stderr)

    config_path = Path(env["SUBFLOW_CONFIG_PATH"])
    config_path.write_text(json.dumps({
      "inbounds": [
        {
          "type": "anytls",
          "tag": "anytls-443",
          "tls": {
            "enabled": True,
            "server_name": "any.example.com",
            "acme": {
              "dns01_challenge": {
                "provider": "cloudflare",
                "api_token": valid_token,
                "zone_token": valid_zone_token,
              },
            },
          },
        },
        {
          "type": "trojan",
          "tag": "trojan-8443",
          "tls": {
            "enabled": True,
            "server_name": "trojan.example.com",
            "acme": {
              "dns01_challenge": {
                "provider": "cloudflare",
                "api_token": valid_token,
                "zone_token": valid_zone_token,
              },
            },
          },
        },
        {
          "type": "tuic",
          "tag": "tuic-alidns",
          "tls": {
            "enabled": True,
            "server_name": "tuic.example.com",
            "acme": {
              "dns01_challenge": {
                "provider": "alidns",
                "access_key_secret": "KEEP_ALIDNS_SECRET",
              },
            },
          },
        },
      ],
    }), encoding="utf-8")
    replacement_file = self.root / "replacement-token"
    replacement_file.write_text("REPLACEMENT_" + "R" * 28, encoding="ascii")
    rotated = self._run(
      str(SB_SH), "acme", "import-cloudflare", replacement_file.as_posix(), env=env,
    )
    blocked_in_use_clear = self._run(str(SB_SH), "acme", "clear", "YES", env=env)
    replacement_token = replacement_file.read_text(encoding="ascii")
    self.assertEqual(rotated.returncode, 0, rotated.stderr)
    self.assertNotEqual(blocked_in_use_clear.returncode, 0)
    self.assertIn("在线轮换", rotated.stdout)
    self.assertIn("TLS 协议", blocked_in_use_clear.stderr)
    self.assertEqual(json.loads(secret_path.read_text(encoding="utf-8")), {
      "api_token": replacement_token,
    })
    rotated_config = json.loads(config_path.read_text(encoding="utf-8"))
    for inbound in rotated_config["inbounds"][:2]:
      challenge = inbound["tls"]["acme"]["dns01_challenge"]
      self.assertEqual(challenge, {
        "provider": "cloudflare",
        "api_token": replacement_token,
      })
    self.assertEqual(
      rotated_config["inbounds"][2]["tls"]["acme"]["dns01_challenge"],
      {"provider": "alidns", "access_key_secret": "KEEP_ALIDNS_SECRET"},
    )
    self.assertNotIn(valid_token, rotated.stdout + rotated.stderr)
    self.assertNotIn(valid_zone_token, rotated.stdout + rotated.stderr)
    self.assertNotIn(replacement_token, rotated.stdout + rotated.stderr)

    config_path.write_text('{"inbounds":[]}\n', encoding="utf-8")
    rotated_secret = secret_path.read_bytes()

    pending_dir = state_dir / ".txn.pending"
    pending_dir.mkdir()
    (pending_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    blocked_import = self._run(str(SB_SH), "acme", "import-cloudflare", valid_file.as_posix(), env=env)
    blocked_clear = self._run(str(SB_SH), "acme", "clear", "YES", env=env)
    self.assertNotEqual(blocked_import.returncode, 0)
    self.assertNotEqual(blocked_clear.returncode, 0)
    self.assertIn("未完成事务", blocked_import.stderr + blocked_clear.stderr)
    self.assertEqual(secret_path.read_bytes(), rotated_secret)

  def test_online_rotation_service_failure_restores_secret_and_config(self):
    self._build()
    state_dir, secrets_dir, secret_path, data_dir, env = self._fixture()
    old_token = "OLD_" + "O" * 36
    new_token = "NEW_" + "N" * 36
    old_file = self.root / "old-token"
    new_file = self.root / "new-token"
    old_file.write_text(old_token, encoding="ascii")
    new_file.write_text(new_token, encoding="ascii")
    imported = self._run(str(SB_SH), "acme", "import-cloudflare", old_file.as_posix(), env=env)
    self.assertEqual(imported.returncode, 0, imported.stderr)
    config_path = Path(env["SUBFLOW_CONFIG_PATH"])
    config_path.write_text(json.dumps({
      "inbounds": [{
        "type": "trojan",
        "tag": "trojan-443",
        "users": [],
        "tls": {
          "enabled": True,
          "server_name": "trojan.example.com",
          "acme": {
            "dns01_challenge": {"provider": "cloudflare", "api_token": old_token},
          },
        },
      }],
    }), encoding="utf-8")
    old_config = config_path.read_bytes()
    old_secret = secret_path.read_bytes()
    env["SUBFLOW_TEST_FAIL_RESTART_ONCE"] = "1"

    result = self._run(str(SB_SH), "acme", "import-cloudflare", new_file.as_posix(), env=env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("已恢复旧凭据和配置", result.stderr)
    self.assertEqual(config_path.read_bytes(), old_config)
    self.assertEqual(secret_path.read_bytes(), old_secret)
    self.assertNotIn(old_token, result.stdout + result.stderr)
    self.assertNotIn(new_token, result.stdout + result.stderr)
    self.assertFalse(any(state_dir.glob(".txn.*")))

  def test_recover_restores_interrupted_online_rotation(self):
    self._build()
    state_dir, secrets_dir, secret_path, data_dir, env = self._fixture()
    config_path = Path(env["SUBFLOW_CONFIG_PATH"])
    service_target = Path(env["SUBFLOW_SYSTEMD_UNIT_PATH"])
    old_token = "OLD_" + "P" * 36
    new_token = "NEW_" + "Q" * 36
    old_config = {
      "inbounds": [{
        "type": "anytls",
        "tag": "anytls-443",
        "tls": {
          "enabled": True,
          "server_name": "any.example.com",
          "acme": {
            "dns01_challenge": {"provider": "cloudflare", "api_token": old_token},
          },
        },
      }],
    }
    old_secret = {"api_token": old_token}
    config_path.write_text(json.dumps(old_config), encoding="utf-8")
    secrets_dir.mkdir(parents=True, exist_ok=True)
    secret_path.write_text(json.dumps(old_secret), encoding="utf-8")

    txn_dir = state_dir / ".txn.acmerotate"
    backup_dir = txn_dir / "backup"
    backup_dir.mkdir(parents=True)
    (backup_dir / "config.json").write_text(json.dumps(old_config), encoding="utf-8")
    (backup_dir / "cloudflare-acme.json").write_text(json.dumps(old_secret), encoding="utf-8")
    (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (txn_dir / "acme-rotation.manifest.json").write_text(json.dumps({
      "version": 1,
      "kind": "cloudflare-acme-rotation",
      "txn_dir": txn_dir.as_posix(),
      "state_dir": state_dir.as_posix(),
      "config_target": config_path.as_posix(),
      "secret_target": secret_path.as_posix(),
      "service_target": service_target.as_posix(),
      "init": "systemd",
      "config_backup": "backup/config.json",
      "secret_backup": "backup/cloudflare-acme.json",
      "secret_existed": True,
      "service_was_active": True,
    }), encoding="utf-8")
    config_path.write_text(json.dumps({
      "inbounds": [{"tls": {"acme": {"dns01_challenge": {
        "provider": "cloudflare", "api_token": new_token,
      }}}}],
    }), encoding="utf-8")
    secret_path.write_text(json.dumps({"api_token": new_token}), encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(json.loads(config_path.read_text(encoding="utf-8")), old_config)
    self.assertEqual(json.loads(secret_path.read_text(encoding="utf-8")), old_secret)
    self.assertFalse(txn_dir.exists())


if __name__ == "__main__":
  unittest.main()