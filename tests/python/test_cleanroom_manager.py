import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
import re


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SH = REPO_ROOT / "vps" / "singbox-cleanroom" / "build.sh"
SB_SH = REPO_ROOT / "vps" / "singbox-cleanroom" / "sb.sh"
RELEASE_MANIFEST = REPO_ROOT / "configs" / "sing-box-releases.json"
BASH = shutil.which("bash") or "bash"


class CleanroomManagerTests(unittest.TestCase):
  def setUp(self):
    self.temp_dir = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp_dir.cleanup)
    self.root = Path(self.temp_dir.name)

  def _run(self, *args, env=None, cwd=REPO_ROOT):
    run_env = os.environ.copy()
    run_env.setdefault("LC_ALL", "C")
    if env:
      run_env.update(env)
    return subprocess.run(
      [BASH, *args],
      cwd=cwd,
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
    return path

  def _build(self):
    result = self._run(str(BUILD_SH))
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertTrue(SB_SH.exists())

  def _fixture_paths(self):
    config_path = self.root / "config.json"
    users_path = self.root / "users.json"
    meta_path = self.root / "meta.json"
    index_path = self.root / "subscriptions.json"
    state_dir = self.root / "state"
    secrets_dir = state_dir / "secrets"
    state_dir.mkdir(parents=True, exist_ok=True)
    secrets_dir.mkdir(parents=True, exist_ok=True)
    secrets_dir.chmod(0o700)
    return config_path, users_path, meta_path, index_path, state_dir, secrets_dir

  def _write_fixture(self, config_path, users_path, meta_path):
    config_path.write_text(json.dumps({
      "inbounds": [
        {
          "type": "vless",
          "tag": "reality-443",
          "listen_port": 443,
          "password": "NON_SS_TOP_LEVEL_PASSWORD",
          "users": [
            {"name": "tokyo@alice", "uuid": "alice-uuid", "flow": "xtls-rprx-vision", "server_only_note": "nope"},
            {"name": "tokyo@bob", "uuid": "bob-uuid", "flow": "xtls-rprx-vision"},
          ],
          "tls": {"server_name": "www.example.com", "reality": {"enabled": True, "short_id": ["abcd1234"], "private_key": "REALITY_PRIVATE_KEY"}},
        },
        {
          "type": "shadowsocks",
          "tag": "ss-8388",
          "listen_port": 8388,
          "method": "2022-blake3-aes-128-gcm",
          "password": "SS2022_SERVER_PASSWORD",
          "users": [
            {"name": "osaka@alice", "password": "SS2022_USER_PASSWORD"},
            {"name": "osaka@bob", "password": "BOB_PASSWORD"},
          ],
        },
        {
          "type": "vless",
          "tag": "admin-8443",
          "listen_port": 8443,
          "users": [
            {"name": "control", "uuid": "admin-uuid", "flow": "xtls-rprx-vision"},
          ],
          "tls": {"server_name": "admin.example.com", "reality": {"enabled": True, "short_id": ["11223344"], "private_key": "ADMIN_PRIVATE_KEY"}},
        },
      ],
    }), encoding="utf-8")
    config_path.chmod(0o600)
    users_path.write_text(json.dumps({
      "schema_version": 1,
      "users": {
        "alice": {"enabled": True, "disabled_reason": None, "quota_gb": 100, "used_up_bytes": 10, "used_down_bytes": 20, "manual_added_bytes": 3, "last_live_up_bytes": 4, "last_live_down_bytes": 5, "last_reset_period": "2026-08", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": ["node-a"]},
        "bob": {"enabled": True, "disabled_reason": None, "quota_gb": 50, "used_up_bytes": 1, "used_down_bytes": 2, "manual_added_bytes": 0, "last_live_up_bytes": 0, "last_live_down_bytes": 0, "last_reset_period": "2026-08", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": ["node-b"]},
        "admin": {"enabled": True, "disabled_reason": None, "quota_gb": 0, "used_up_bytes": 0, "used_down_bytes": 0, "manual_added_bytes": 0, "last_live_up_bytes": 0, "last_live_down_bytes": 0, "last_reset_period": "", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": []},
      },
    }), encoding="utf-8")
    users_path.chmod(0o600)
    meta_path.write_text(json.dumps({
      "reality-443": {"public_key": "REALITY_PUBLIC_KEY", "private_key": "META_PRIVATE_KEY"},
      "ss-8388": {"public_key": "SS_UNUSED_PUBLIC_KEY"},
      "admin-8443": {"public_key": "ADMIN_PUBLIC_KEY", "private_key": "ADMIN_META_PRIVATE_KEY"},
    }), encoding="utf-8")
    config_path.chmod(0o600)
    users_path.chmod(0o600)
    meta_path.chmod(0o600)
    meta_path.chmod(0o600)

  def _base_env(self, extra=None):
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    if extra:
      env.update(extra)
    return env

  def _write_rebuild_helper(self, helper_path: Path):
    helper_path.write_text("""import json
import os
from pathlib import Path

def owner(name):
    return name.split('@', 1)[1] if '@' in name else 'admin'

config = json.loads(Path(os.environ['SUBFLOW_CONFIG_PATH']).read_text(encoding='utf-8'))
users = json.loads(Path(os.environ['SUBFLOW_USERS_PATH']).read_text(encoding='utf-8'))
meta = json.loads(Path(os.environ['SUBFLOW_META_PATH']).read_text(encoding='utf-8'))
output = {'schema_version': 1, 'users': {}}

for username, user in sorted(users['users'].items()):
    user_meta = {}
    inbound_list = []
    for inbound in config.get('inbounds', []):
        if username not in [owner(item.get('name', '')) for item in inbound.get('users', [])]:
            continue
        projected_users = []
        for entry in inbound.get('users', []):
            name = entry.get('name', '')
            if owner(name) != username:
                continue
            projected = {'name': name, 'username': username}
            for field in ('uuid', 'password', 'flow'):
                if field in entry:
                    projected[field] = entry[field]
            projected_users.append(projected)
        if not projected_users:
            continue
        projected = {'type': inbound.get('type'), 'tag': inbound.get('tag'), 'listen_port': inbound.get('listen_port'), 'users': projected_users}
        if inbound.get('type') == 'shadowsocks':
          for field in ('method', 'password'):
            if field in inbound:
              projected[field] = inbound[field]
        transport = inbound.get('transport')
        if isinstance(transport, dict):
            selected = {key: transport.get(key) for key in ('type', 'path') if transport.get(key) is not None}
            if selected:
                projected['transport'] = selected
        tls = inbound.get('tls')
        if isinstance(tls, dict):
            tls_out = {}
            if tls.get('server_name') is not None:
                tls_out['server_name'] = tls['server_name']
            reality = tls.get('reality')
            if isinstance(reality, dict):
                tls_out['reality'] = {'enabled': reality.get('enabled'), 'short_id': reality.get('short_id', [])}
            if tls_out:
                projected['tls'] = tls_out
        inbound_list.append(projected)
        tag = inbound.get('tag')
        if (tag and inbound.get('type') == 'vless'
          and inbound.get('tls', {}).get('reality', {}).get('enabled') is True
          and meta.get(tag, {}).get('public_key') is not None):
            user_meta[tag] = {'public_key': meta[tag]['public_key']}
    usage = dict(user)
    usage.setdefault('enabled', True)
    usage.setdefault('disabled_reason', None)
    usage.setdefault('quota_gb', 0)
    usage.setdefault('used_up_bytes', 0)
    usage.setdefault('used_down_bytes', 0)
    usage.setdefault('manual_added_bytes', 0)
    usage.setdefault('last_live_up_bytes', 0)
    usage.setdefault('last_live_down_bytes', 0)
    usage.setdefault('last_reset_period', '')
    usage.setdefault('reset_day', 0)
    usage.setdefault('expire_at', '0')
    usage.setdefault('allow_all_nodes', True)
    usage.setdefault('nodes', [])
    output['users'][username] = {'usage': usage, 'inbounds': inbound_list, 'meta': user_meta}

print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
""", encoding="utf-8")

  def test_cleanroom_build_script_exists(self):
    self.assertTrue(BUILD_SH.exists())

  def test_build_is_deterministic_and_embeds_theme(self):
    self._build()
    first_hash = hashlib.sha256(SB_SH.read_bytes()).hexdigest()
    first_content = SB_SH.read_text(encoding="utf-8")
    self._build()
    self.assertEqual(first_hash, hashlib.sha256(SB_SH.read_bytes()).hexdigest())
    self.assertIn("setup_colors", first_content)
    self.assertIn("SUBFLOW", first_content)
    self.assertNotIn("2026-", first_content)

  def test_approved_release_manifest_is_embedded(self):
    self._build()
    manifest = json.loads(RELEASE_MANIFEST.read_text(encoding="utf-8"))
    latest = manifest["latest"]

    self.assertEqual(manifest["schema_version"], 1)
    self.assertIn(latest, manifest["releases"])
    for arch in ("amd64", "arm64"):
      asset = manifest["releases"][latest]["assets"][arch]
      self.assertEqual(asset["name"], f"sing-box-linux-{arch}")
      self.assertRegex(asset["sha256"], r"^[0-9a-f]{64}$")

    generated = SB_SH.read_text(encoding="utf-8")
    self.assertIn('subflow_release_manifest()', generated)
    self.assertIn(manifest["repository"], generated)
    self.assertIn(manifest["releases"][latest]["assets"]["amd64"]["sha256"], generated)

  def test_no_color_and_old_tg_agent_sync_are_supported(self):
    self._build()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stub(bin_dir, "apt-get", "exit 0")
    self._write_stub(bin_dir, "systemctl", "exit 0")
    self._write_stub(bin_dir, "uname", 'if [[ "${1:-}" == "-m" ]]; then printf "x86_64\\n"; else printf "Linux\\n"; fi')
    env = self._base_env({"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "NO_COLOR": "1", "INVOCATION_ID": "1"})
    self.assertEqual(self._run(str(SB_SH), "--tg-agent-sync", env=env).returncode, 0)
    menu = self._run(str(SB_SH), env=env)
    self.assertEqual(menu.returncode, 0)
    self.assertNotIn("\x1b[", menu.stdout)

  def test_unknown_command_is_non_zero(self):
    self._build()
    result = self._run(str(SB_SH), "does-not-exist")
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("未知命令", result.stderr)

  def test_protocol_registry_has_one_record_per_supported_protocol(self):
    self._build()
    command = f'source "{SB_SH.as_posix()}"; subflow_protocol_registry'

    result = self._run("-c", command)

    self.assertEqual(result.returncode, 0, result.stderr)
    records = [line.split("|") for line in result.stdout.splitlines() if line]
    self.assertEqual([record[0] for record in records], [
      "vless-reality",
      "anytls",
      "shadowsocks-2022",
      "trojan",
      "vmess-ws",
      "vless-ws",
      "tuic",
    ])
    self.assertTrue(all(len(record) == 5 for record in records))
    self.assertEqual(len({record[0] for record in records}), len(records))

  def test_rebuild_projects_fixture_without_leaking_secrets(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture_paths()
    self._write_fixture(config_path, users_path, meta_path)

    bin_dir = self.root / "bin"
    helper_path = self.root / "jq_projection.py"
    helper_path.parent.mkdir(parents=True, exist_ok=True)
    self._write_rebuild_helper(helper_path)
    bin_dir.mkdir()
    self._write_stub(bin_dir, "apt-get", "exit 0")
    self._write_stub(bin_dir, "systemctl", "exit 0")
    self._write_stub(bin_dir, "uname", 'if [[ "${1:-}" == "-m" ]]; then printf "x86_64\\n"; else printf "Linux\\n"; fi')
    self._write_stub(bin_dir, "sing-box", 'if [[ "${1:-}" == "version" ]]; then printf "sing-box 1.0\\nwith_v2ray_api\\nwith_wireguard\\nwith_acme\\n"; exit 0; fi; if [[ "${1:-}" == "check" ]]; then exit 0; fi; exit 0')
    python_executable = Path(sys.executable).as_posix()
    self._write_stub(bin_dir, "jq", f'"{python_executable}" "{helper_path.as_posix()}"')
    self._write_stub(bin_dir, "flock", 'exit 0')

    env = self._base_env({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "SUBFLOW_CONFIG_PATH": str(config_path),
      "SUBFLOW_USERS_PATH": str(users_path),
      "SUBFLOW_META_PATH": str(meta_path),
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH": str(index_path),
      "SUBFLOW_STATE_DIR": str(state_dir),
      "SUBFLOW_SECRETS_DIR": str(secrets_dir),
      "SUBFLOW_LOCK_PATH": str(self.root / "lock"),
      "SUBFLOW_SINGBOX_BIN": str(bin_dir / "sing-box"),
      "INVOCATION_ID": "1",
    })

    result = self._run(str(SB_SH), "rebuild", env=env)
    self.assertEqual(result.returncode, 0, result.stderr)
    payload = json.loads(index_path.read_text(encoding="utf-8"))
    self.assertEqual(payload["schema_version"], 1)
    self.assertIn("alice", payload["users"])
    self.assertIn("admin", payload["users"])
    self.assertEqual(payload["users"]["alice"]["meta"], {
      "reality-443": {"public_key": "REALITY_PUBLIC_KEY"},
    })
    self.assertEqual(payload["users"]["admin"]["inbounds"][0]["users"], [
      {"name": "control", "username": "admin", "uuid": "admin-uuid", "flow": "xtls-rprx-vision"},
    ])
    alice_ss = next(
      inbound
      for inbound in payload["users"]["alice"]["inbounds"]
      if inbound["type"] == "shadowsocks"
    )
    self.assertEqual(alice_ss["password"], "SS2022_SERVER_PASSWORD")
    self.assertEqual(alice_ss["users"][0]["password"], "SS2022_USER_PASSWORD")
    serialized = json.dumps(payload)
    for secret in (
      "REALITY_PRIVATE_KEY",
      "META_PRIVATE_KEY",
      "ADMIN_PRIVATE_KEY",
      "NON_SS_TOP_LEVEL_PASSWORD",
      "SS_UNUSED_PUBLIC_KEY",
    ):
      self.assertNotIn(secret, serialized)
    alice_serialized = json.dumps(payload["users"]["alice"])
    self.assertNotIn("BOB_PASSWORD", alice_serialized)
    self.assertNotIn("bob-uuid", alice_serialized)
    self.assertIn("BOB_PASSWORD", json.dumps(payload["users"]["bob"]))

  def test_check_and_doctor_accept_valid_fixture(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture_paths()
    self._write_fixture(config_path, users_path, meta_path)

    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stub(bin_dir, "apt-get", "exit 0")
    self._write_stub(bin_dir, "systemctl", "exit 0")
    self._write_stub(bin_dir, "uname", 'if [[ "${1:-}" == "-m" ]]; then printf "x86_64\\n"; else printf "Linux\\n"; fi')
    self._write_stub(bin_dir, "sing-box", 'if [[ "${1:-}" == "version" ]]; then printf "sing-box 1.0\\nwith_v2ray_api\\nwith_wireguard\\nwith_acme\\n"; exit 0; fi; if [[ "${1:-}" == "check" ]]; then exit 0; fi; exit 0')
    self._write_stub(bin_dir, "jq", 'exit 0')
    self._write_stub(bin_dir, "openssl", 'exit 0')
    self._write_stub(bin_dir, "tar", 'exit 0')
    self._write_stub(bin_dir, "sha256sum", 'exit 0')
    self._write_stub(bin_dir, "flock", 'exit 0')
    self._write_stub(bin_dir, "python3", 'exit 0')

    env = self._base_env({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "SUBFLOW_CONFIG_PATH": str(config_path),
      "SUBFLOW_USERS_PATH": str(users_path),
      "SUBFLOW_META_PATH": str(meta_path),
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH": str(index_path),
      "SUBFLOW_STATE_DIR": str(state_dir),
      "SUBFLOW_SECRETS_DIR": str(secrets_dir),
      "SUBFLOW_LOCK_PATH": str(self.root / "lock"),
      "SUBFLOW_SINGBOX_BIN": str(bin_dir / "sing-box"),
      "INVOCATION_ID": "1",
    })

    self.assertEqual(self._run(str(SB_SH), "rebuild", env=env).returncode, 0)
    self.assertEqual(self._run(str(SB_SH), "check", env=env).returncode, 0)
    doctor = self._run(str(SB_SH), "doctor", env=env)
    self.assertEqual(doctor.returncode, 0, doctor.stderr)
    self.assertIn("doctor 通过", doctor.stdout)

  def test_pending_transaction_blocks_writes_and_maintenance(self):
    self._build()
    state_dir = self.root / "state"
    pending_dir = state_dir / ".txn.crashed"
    pending_dir.mkdir(parents=True)
    marker = pending_dir / "recovery.pending"
    marker.write_text("pending\n", encoding="utf-8")
    index_path = self.root / "subscriptions.json"
    original = '{"schema_version":1,"users":{"sentinel":{}}}\n'
    index_path.write_text(original, encoding="utf-8")

    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stub(bin_dir, "flock", "exit 0")
    env = self._base_env({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "SUBFLOW_STATE_DIR": str(state_dir),
      "SUBFLOW_LOCK_PATH": str(self.root / "lock"),
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH": str(index_path),
    })

    command = (
      f'source "{SB_SH.as_posix()}"; '
      'if main rebuild; then exit 0; else exit 42; fi'
    )
    rebuild = self._run("-c", command, env=env)
    maintenance = self._run(str(SB_SH), "--daily-maintenance", env=env)

    self.assertNotEqual(rebuild.returncode, 0)
    self.assertNotEqual(maintenance.returncode, 0)
    self.assertTrue(marker.exists())
    self.assertEqual(index_path.read_text(encoding="utf-8"), original)
    self.assertIn("未完成事务", rebuild.stderr + maintenance.stderr)

  def test_transaction_abort_rejects_paths_outside_transaction_root(self):
    self._build()
    state_dir = self.root / "state"
    state_dir.mkdir()
    sentinel = self.root / "must-stay"
    sentinel.mkdir()
    command = (
      f'source "{SB_SH.as_posix()}"; '
      f'SUBFLOW_STATE_DIR="{state_dir.as_posix()}"; '
      f'if subflow_txn_abort "{sentinel.as_posix()}"; then exit 0; else exit 42; fi'
    )

    result = self._run("-c", command)

    self.assertNotEqual(result.returncode, 0)
    self.assertTrue(sentinel.exists())
    self.assertIn("非法事务目录", result.stderr)

  def test_required_command_failure_survives_conditional_context(self):
    self._build()
    command = (
      f'source "{SB_SH.as_posix()}"; '
      'subflow_has_cmd() { [[ "$1" != "missing" ]]; }; '
      'if subflow_require_cmd missing present; then exit 0; else exit 42; fi'
    )

    result = self._run("-c", command)

    self.assertEqual(result.returncode, 42)
    self.assertIn("缺少必要命令: missing", result.stderr)

  def test_missing_required_build_tag_returns_non_zero(self):
    self._build()
    command = (
      f'source "{SB_SH.as_posix()}"; '
      'subflow_doctor_version_has_tags "with_wireguard with_acme"'
    )

    result = self._run("-c", command)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("with_v2ray_api", result.stderr)

  def test_platform_detection_matrix(self):
    self._build()
    package_managers = ("apt-get", "dnf", "yum", "pacman", "apk", "zypper")
    init_systems = (("systemd", "systemctl"), ("openrc", "rc-service"))
    architectures = (("x86_64", "amd64"), ("aarch64", "arm64"))

    for package_manager in package_managers:
      for init_name, init_command in init_systems:
        for machine, expected_arch in architectures:
          with self.subTest(package_manager=package_manager, init=init_name, arch=machine):
            invocation = "INVOCATION_ID=1" if init_name == "systemd" else "unset INVOCATION_ID"
            command = f'''
              source "{SB_SH.as_posix()}"
              subflow_has_cmd() {{
                case "$1" in
                  {package_manager}|{init_command}) return 0 ;;
                  *) return 1 ;;
                esac
              }}
              uname() {{
                if [[ "${{1:-}}" == "-m" ]]; then printf '%s\\n' "{machine}"; else printf 'Linux\\n'; fi
              }}
              {invocation}
              subflow_detect_platform
            '''
            result = self._run("-c", command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
              result.stdout.strip(),
              f"{package_manager}|{init_name}|{expected_arch}",
            )

  def test_cleanroom_sources_exclude_remote_execution_and_telegram(self):
    source_files = [
      BUILD_SH,
      *sorted((BUILD_SH.parent / "lib").glob("*.sh")),
      *sorted((BUILD_SH.parent / "python").glob("*.py")),
    ]
    source = "\n".join(path.read_text(encoding="utf-8") for path in source_files)

    self.assertIsNone(re.search(r"\beval\b", source))
    self.assertIsNone(re.search(r"curl[^\n|]*\|[^\n]*(?:bash|sh)", source))
    self.assertIsNone(re.search(r"wget[^\n|]*\|[^\n]*(?:bash|sh)", source))
    self.assertNotIn("api.telegram.org", source)
    rebuild_source = (BUILD_SH.parent / "lib" / "84_rebuild.sh").read_text(encoding="utf-8")
    self.assertIn('$inbound.type == "shadowsocks"', rebuild_source)
    self.assertIn('($inbound.tls.reality.enabled // false)', rebuild_source)


if __name__ == "__main__":
  unittest.main()
