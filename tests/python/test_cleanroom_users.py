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


class CleanroomUsersTests(unittest.TestCase):
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

  def _fixture(self):
    config_path = self.root / "config.json"
    users_path = self.root / "users.json"
    meta_path = self.root / "meta.json"
    index_path = self.root / "subscriptions.json"
    state_dir = self.root / "state"
    secrets_dir = state_dir / "secrets"
    state_dir.mkdir(parents=True, exist_ok=True)
    secrets_dir.mkdir(parents=True, exist_ok=True)
    secrets_dir.chmod(0o700)
    config_path.write_text(json.dumps({"inbounds": []}), encoding="utf-8")
    users_path.write_text(json.dumps({
      "schema_version": 1,
      "users": {
        "alice": {"enabled": True, "disabled_reason": None, "quota_gb": 1, "used_up_bytes": 0, "used_down_bytes": 0, "manual_added_bytes": 0, "last_live_up_bytes": 0, "last_live_down_bytes": 0, "last_reset_period": "", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": []},
        "bob": {"enabled": True, "disabled_reason": None, "quota_gb": 2, "used_up_bytes": 0, "used_down_bytes": 0, "manual_added_bytes": 0, "last_live_up_bytes": 0, "last_live_down_bytes": 0, "last_reset_period": "", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": []},
        "admin": {"enabled": True, "disabled_reason": None, "quota_gb": 0, "used_up_bytes": 0, "used_down_bytes": 0, "manual_added_bytes": 0, "last_live_up_bytes": 0, "last_live_down_bytes": 0, "last_reset_period": "", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": []},
      },
    }), encoding="utf-8")
    meta_path.write_text(json.dumps({}), encoding="utf-8")
    index_path.write_text(json.dumps({"schema_version": 1, "users": {}}), encoding="utf-8")
    return config_path, users_path, meta_path, index_path, state_dir, secrets_dir

  def _seed_managed_inbounds(self, config_path: Path, meta_path: Path):
    config_path.write_text(json.dumps({
      "inbounds": [
        {
          "type": "vless",
          "tag": "reality-443",
          "listen": "::",
          "listen_port": 443,
          "users": [
            {"name": "reality-443@admin", "uuid": "00000000-0000-4000-8000-000000000001", "flow": "xtls-rprx-vision"},
            {"name": "reality-443@alice", "uuid": "00000000-0000-4000-8000-000000000002", "flow": "xtls-rprx-vision"},
            {"name": "reality-443@bob", "uuid": "00000000-0000-4000-8000-000000000003", "flow": "xtls-rprx-vision"},
          ],
          "tls": {
            "enabled": True,
            "server_name": "www.example.com",
            "reality": {
              "enabled": True,
              "handshake": {"server": "www.example.com", "server_port": 443},
              "private_key": "A" * 43,
              "short_id": ["0123456789abcdef"],
            },
          },
        },
        {
          "type": "shadowsocks",
          "tag": "ss-8388",
          "listen": "::",
          "listen_port": 8388,
          "network": "tcp",
          "method": "2022-blake3-aes-128-gcm",
          "password": "SERVER_PASSWORD",
          "users": [
            {"name": "ss-8388@admin", "password": "ADMIN_PASSWORD"},
            {"name": "ss-8388@alice", "password": "ALICE_PASSWORD"},
            {"name": "ss-8388@bob", "password": "BOB_PASSWORD"},
          ],
        },
        {
          "type": "anytls",
          "tag": "anytls-7443",
          "listen_port": 7443,
          "users": [
            {"name": "anytls-7443@admin", "password": "ANYTLS_ADMIN_PASSWORD"},
            {"name": "anytls-7443@alice", "password": "ANYTLS_ALICE_PASSWORD"},
            {"name": "anytls-7443@bob", "password": "ANYTLS_BOB_PASSWORD"},
          ],
          "tls": {
            "enabled": True,
            "server_name": "any.example.com",
            "acme": {
              "domain": ["any.example.com"],
              "email": "ops@example.com",
              "dns01_challenge": {"provider": "cloudflare", "api_token": "ACME_TEST_TOKEN_SECRET"},
            },
          },
        },
        {
          "type": "trojan",
          "tag": "trojan-8443",
          "listen_port": 8443,
          "users": [
            {"name": "trojan-8443@admin", "password": "TROJAN_ADMIN_PASSWORD"},
            {"name": "trojan-8443@alice", "password": "TROJAN_ALICE_PASSWORD"},
            {"name": "trojan-8443@bob", "password": "TROJAN_BOB_PASSWORD"},
          ],
          "tls": {
            "enabled": True,
            "server_name": "trojan.example.com",
            "acme": {
              "domain": ["trojan.example.com"],
              "email": "ops@example.com",
              "dns01_challenge": {"provider": "cloudflare", "api_token": "ACME_TEST_TOKEN_SECRET"},
            },
          },
        },
        {
          "type": "tuic",
          "tag": "tuic-9443",
          "listen_port": 9443,
          "users": [
            {"name": "tuic-9443@admin", "uuid": "00000000-0000-4000-8000-000000000011", "password": "TUIC_ADMIN_PASSWORD"},
            {"name": "tuic-9443@alice", "uuid": "00000000-0000-4000-8000-000000000012", "password": "TUIC_ALICE_PASSWORD"},
            {"name": "tuic-9443@bob", "uuid": "00000000-0000-4000-8000-000000000013", "password": "TUIC_BOB_PASSWORD"},
          ],
          "tls": {
            "enabled": True,
            "server_name": "tuic.example.com",
            "acme": {
              "domain": ["tuic.example.com"],
              "email": "ops@example.com",
              "dns01_challenge": {"provider": "cloudflare", "api_token": "ACME_TEST_TOKEN_SECRET"},
            },
          },
        },
      ],
      "outbounds": [{"type": "direct", "tag": "direct"}],
    }), encoding="utf-8")
    meta_path.write_text(json.dumps({
      "reality-443": {"public_key": "B" * 43},
    }), encoding="utf-8")

  def _common_env(self, bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir, extra=None):
    unit_path = self.root / "systemd" / "sing-box.service"
    unit_path.parent.mkdir(parents=True, exist_ok=True)
    unit_path.write_text("test service\n", encoding="utf-8")
    env = os.environ.copy()
    env.update({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "SUBFLOW_CONFIG_PATH": config_path.as_posix(),
      "SUBFLOW_USERS_PATH": users_path.as_posix(),
      "SUBFLOW_META_PATH": meta_path.as_posix(),
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH": index_path.as_posix(),
      "SUBFLOW_STATE_DIR": state_dir.as_posix(),
      "SUBFLOW_SECRETS_DIR": secrets_dir.as_posix(),
      "SUBFLOW_LOCK_PATH": (self.root / "lock").as_posix(),
      "SUBFLOW_SINGBOX_BIN": (bin_dir / "sing-box").as_posix(),
      "SUBFLOW_INIT": "systemd",
      "SUBFLOW_SYSTEMD_UNIT_PATH": unit_path.as_posix(),
      "INVOCATION_ID": "1",
      "LC_ALL": "C",
    })
    if extra:
      env.update(extra)
    return env

  def _write_common_stubs(self, bin_dir: Path, *, flock_body="exit 0", jq_fail_mode="", systemctl_body="exit 0"):
    self._write_stub(bin_dir, "apt-get", "exit 0")
    self._write_stub(bin_dir, "systemctl", systemctl_body)
    self._write_stub(bin_dir, "uname", 'if [[ "${1:-}" == "-m" ]]; then printf "x86_64\\n"; else printf "Linux\\n"; fi')
    self._write_stub(bin_dir, "flock", flock_body)
    self._write_stub(bin_dir, "sing-box", 'if [[ "${1:-}" == "version" ]]; then printf "sing-box 1.0\\nwith_v2ray_api\\nwith_wireguard\\nwith_acme\\n"; exit 0; fi; if [[ "${1:-}" == "check" ]]; then exit 0; fi; exit 0')
    self._write_stub(bin_dir, "python3", f'exec "{PYTHON.as_posix()}" "$@"')
    self._write_jq_stub(bin_dir, jq_fail_mode)

  def _write_jq_stub(self, bin_dir: Path, fail_mode: str):
    helper = self.root / "jq_stub.py"
    helper.write_text("""import json
import os
import sys
from pathlib import Path


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def dump(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + '\\n', encoding='utf-8')


def owner(name):
    return name.split('@', 1)[1] if isinstance(name, str) and '@' in name else 'admin'


def project_inbounds(config, meta, username):
  projected_inbounds = []
  projected_meta = {}
  for inbound in config.get('inbounds', []):
    selected_users = []
    for entry in inbound.get('users', []):
      if owner(entry.get('name')) != username:
        continue
      selected = {'name': entry.get('name'), 'username': username}
      for field in ('uuid', 'password', 'flow'):
        if entry.get(field) not in (None, ''):
          selected[field] = entry[field]
      selected_users.append(selected)
    if not selected_users:
      continue
    selected_inbound = {
      'type': inbound.get('type'),
      'tag': inbound.get('tag'),
      'listen_port': inbound.get('listen_port'),
      'users': selected_users,
    }
    if inbound.get('type') == 'shadowsocks':
      for field in ('method', 'password'):
        if inbound.get(field) is not None:
          selected_inbound[field] = inbound[field]
    tls = inbound.get('tls')
    if isinstance(tls, dict):
      selected_tls = {}
      if tls.get('server_name') is not None:
        selected_tls['server_name'] = tls['server_name']
      reality = tls.get('reality')
      if isinstance(reality, dict):
        selected_tls['reality'] = {
          'enabled': reality.get('enabled'),
          'short_id': reality.get('short_id', []),
        }
      if selected_tls:
        selected_inbound['tls'] = selected_tls
    projected_inbounds.append(selected_inbound)
    tag = inbound.get('tag')
    if (
      inbound.get('type') == 'vless'
      and isinstance(inbound.get('tls'), dict)
      and isinstance(inbound['tls'].get('reality'), dict)
      and inbound['tls']['reality'].get('enabled') is True
      and isinstance(meta.get(tag), dict)
      and meta[tag].get('public_key') is not None
    ):
      projected_meta[tag] = {'public_key': meta[tag]['public_key']}
  return projected_inbounds, projected_meta


args = sys.argv[1:]
named = {'arg': {}, 'argjson': {}, 'argfile': {}}
flags = set()
positionals = []
index = 0
while index < len(args):
  token = args[index]
  if token in ('--arg', '--argjson', '--argfile'):
    kind = token[2:]
    named[kind][args[index + 1]] = args[index + 2]
    index += 3
    continue
  if token in ('-e', '-r', '-n', '-c'):
    flags.add(token)
    index += 1
    continue
  if token.startswith('-'):
    index += 1
    continue
  positionals.append(token)
  index += 1

query = ' '.join((positionals[0] if positionals else '').split())
input_file = next(
  (item for item in reversed(positionals[1:]) if Path(item).exists()),
  None,
)

if '-n' in flags and named['argfile']:
  users_file = named['argfile']['users']
  if (os.environ.get('SUBFLOW_JQ_FAIL_MODE') == 'mutation-index'
      and users_file != os.environ.get('SUBFLOW_USERS_PATH')):
    sys.exit(1)
  users = load(users_file)
  config = load(named['argfile']['config'])
  meta = load(named['argfile']['meta'])
  output = {'schema_version': 1, 'users': {}}
  for username, user in sorted(users['users'].items()):
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
    inbounds, user_meta = project_inbounds(config, meta, username)
    output['users'][username] = {'usage': usage, 'inbounds': inbounds, 'meta': user_meta}
  print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
  sys.exit(0)

if '-n' in flags and not named['argfile']:
  if query.startswith('{ version: 1,'):
    output = {
      'version': 1,
      'txn_dir': named['arg']['txn_dir'],
      'state_dir': named['arg']['state_dir'],
      'users_target': named['arg']['users_target'],
      'index_target': named['arg']['index_target'],
      'users_backup': named['arg']['users_backup'],
      'index_backup': named['arg']['index_backup'],
      'users_existed': named['argjson']['users_existed'] == 'true',
      'index_existed': named['argjson']['index_existed'] == 'true',
      'operation': named['arg']['operation'],
      'username': named['arg']['username'],
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    sys.exit(0)
  sys.exit(1)

if query == '.':
  load(input_file)
  sys.exit(0)

if query == 'type == "object"':
    sys.exit(0 if isinstance(load(input_file), dict) else 1)
if query == 'type == "array"':
    sys.exit(0 if isinstance(load(input_file), list) else 1)
if query == 'type == "object" and .schema_version == 1 and (.users | type == "object")':
    data = load(input_file)
    sys.exit(0 if isinstance(data, dict) and data.get('schema_version') == 1 and isinstance(data.get('users'), dict) else 1)
if query.startswith('type == "object" and .version == 1'):
    data = load(input_file)
    valid = (
      isinstance(data, dict)
      and data.get('version') == 1
      and data.get('txn_dir') == named['arg'].get('txn_dir')
      and data.get('state_dir') == named['arg'].get('state_dir')
      and data.get('users_target') == named['arg'].get('users_target')
      and data.get('index_target') == named['arg'].get('index_target')
      and data.get('users_backup') == 'backup/users.json'
      and data.get('index_backup') == 'backup/subscriptions.json'
      and type(data.get('users_existed')) is bool
      and type(data.get('index_existed')) is bool
    )
    sys.exit(0 if valid else 1)
if query == 'type == "object" and (.inbounds | type == "array")':
    data = load(input_file)
    sys.exit(0 if isinstance(data, dict) and isinstance(data.get('inbounds'), list) else 1)
if query in ('.users_existed', '.index_existed'):
  value = load(input_file)[query[1:]]
  print('true' if value else 'false')
  sys.exit(0)

file_path = input_file
if file_path is None:
    sys.exit(1)
data = load(file_path)
program = query
username = named['arg'].get('u') or named['arg'].get('username') or named['arg'].get('name')
quota_value = named['argjson'].get('quota') or named['argjson'].get('add')
quota = int(quota_value) if quota_value is not None else None
reset_value = named['argjson'].get('reset') or named['argjson'].get('reset_day')
reset_day = int(reset_value) if reset_value is not None else None
expire = named['arg'].get('expire')
if username is None:
    username = 'alice'
users = data['users']
if 'del(.users[$u])' in program or 'del(.users[$username])' in program:
    users.pop(username, None)
elif '.disabled_reason = "manual"' in program:
    users[username]['enabled'] = False
    users[username]['disabled_reason'] = 'manual'
elif '.enabled = true' in program and '.disabled_reason = null' in program:
    users[username]['enabled'] = True
    users[username]['disabled_reason'] = None
elif '.quota_gb = $quota' in program and '.users[$u] = {' not in program:
    users[username]['quota_gb'] = quota
elif '.expire_at = $exp' in program or '.expire_at = $expire' in program:
    users[username]['expire_at'] = expire
elif '.reset_day = $reset' in program or '.reset_day = $reset_day' in program:
    users[username]['reset_day'] = reset_day
else:
    users[username] = {
        'enabled': True,
        'disabled_reason': None,
        'quota_gb': quota if quota is not None else 0,
        'used_up_bytes': 0,
        'used_down_bytes': 0,
        'manual_added_bytes': 0,
        'last_live_up_bytes': 0,
        'last_live_down_bytes': 0,
        'last_reset_period': '',
        'reset_day': reset_day if reset_day is not None else 0,
        'expire_at': expire if expire is not None else '0',
        'allow_all_nodes': True,
        'nodes': [],
    }
data['schema_version'] = 1
data['users'] = dict(sorted(users.items()))
print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))
sys.exit(0)
""", encoding="utf-8")
    self._write_stub(bin_dir, "jq", f'exec "{PYTHON.as_posix()}" "{helper.as_posix()}" "$@"')

  def test_users_list_add_set_toggle_and_delete(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)

    result = self._run(str(SB_SH), "users", "add", "carol", "--quota", "12", "--reset-day", "32", "--expire", "2026-12-31", env=env)
    self.assertEqual(result.returncode, 0, result.stderr)

    listing = self._run(str(SB_SH), "users", "list", env=env)
    self.assertEqual(listing.returncode, 0, listing.stderr)
    self.assertIn("carol", listing.stdout)

    self.assertEqual(self._run(str(SB_SH), "users", "set-quota", "carol", "88", env=env).returncode, 0)
    self.assertEqual(self._run(str(SB_SH), "users", "set-expire", "carol", "0", env=env).returncode, 0)
    self.assertEqual(self._run(str(SB_SH), "users", "set-reset-day", "carol", "29", env=env).returncode, 0)
    self.assertEqual(self._run(str(SB_SH), "users", "disable", "carol", env=env).returncode, 0)
    self.assertEqual(self._run(str(SB_SH), "users", "enable", "carol", env=env).returncode, 0)

    payload = json.loads(users_path.read_text(encoding="utf-8"))
    self.assertEqual(payload["users"]["carol"]["quota_gb"], 88)
    self.assertEqual(payload["users"]["carol"]["expire_at"], "0")
    self.assertEqual(payload["users"]["carol"]["reset_day"], 29)
    self.assertTrue(payload["users"]["carol"]["enabled"])
    self.assertIn("carol", json.loads(index_path.read_text(encoding="utf-8"))["users"])

    delete_admin = self._run(str(SB_SH), "users", "delete", "admin", "YES", env=env)
    self.assertNotEqual(delete_admin.returncode, 0)
    self.assertIn("admin", delete_admin.stderr)

    delete_unknown = self._run(str(SB_SH), "users", "delete", "ghost", "YES", env=env)
    self.assertNotEqual(delete_unknown.returncode, 0)
    self.assertIn("未知用户", delete_unknown.stderr)

    self.assertNotEqual(self._run(str(SB_SH), "users", "set-quota", "carol", "-1", env=env).returncode, 0)
    self.assertNotEqual(self._run(str(SB_SH), "users", "set-expire", "carol", "2026-02-30", env=env).returncode, 0)
    self.assertNotEqual(self._run(str(SB_SH), "users", "set-reset-day", "carol", "33", env=env).returncode, 0)

  def test_candidate_index_failure_rolls_back_users_and_index(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir, jq_fail_mode="mutation-index")
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir, extra={"SUBFLOW_JQ_FAIL_MODE": "mutation-index"})

    before_users = users_path.read_text(encoding="utf-8")
    before_index = index_path.read_text(encoding="utf-8")
    result = self._run(str(SB_SH), "users", "add", "carol", "--quota", "12", "--reset-day", "0", "--expire", "0", env=env)
    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(json.loads(users_path.read_text(encoding="utf-8")), json.loads(before_users))
    self.assertEqual(json.loads(index_path.read_text(encoding="utf-8")), json.loads(before_index))

  def test_user_lifecycle_updates_runtime_credentials_and_index(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    self._seed_managed_inbounds(config_path, meta_path)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)

    disabled = self._run(str(SB_SH), "users", "disable", "alice", env=env)
    self.assertEqual(disabled.returncode, 0, disabled.stderr)
    disabled_config = json.loads(config_path.read_text(encoding="utf-8"))
    self.assertTrue(all(
      all(not entry["name"].endswith("@alice") for entry in inbound.get("users", []))
      for inbound in disabled_config["inbounds"]
    ))
    disabled_index = json.loads(index_path.read_text(encoding="utf-8"))
    self.assertFalse(disabled_index["users"]["alice"]["usage"]["enabled"])
    self.assertEqual(disabled_index["users"]["alice"]["inbounds"], [])
    self.assertNotIn("00000000-0000-4000-8000-000000000002", config_path.read_text(encoding="utf-8"))
    self.assertNotIn("ALICE_PASSWORD", config_path.read_text(encoding="utf-8"))

    enabled = self._run(str(SB_SH), "users", "enable", "alice", env=env)
    self.assertEqual(enabled.returncode, 0, enabled.stderr)
    enabled_config = json.loads(config_path.read_text(encoding="utf-8"))
    alice_credentials = [
      entry
      for inbound in enabled_config["inbounds"]
      for entry in inbound.get("users", [])
      if entry["name"].endswith("@alice")
    ]
    self.assertEqual(len(alice_credentials), 5)
    credentials_by_tag = {entry["name"].split("@", 1)[0]: entry for entry in alice_credentials}
    self.assertNotEqual(credentials_by_tag["reality-443"].get("uuid"), "00000000-0000-4000-8000-000000000002")
    self.assertNotEqual(credentials_by_tag["ss-8388"].get("password"), "ALICE_PASSWORD")
    self.assertNotEqual(credentials_by_tag["anytls-7443"].get("password"), "ANYTLS_ALICE_PASSWORD")
    self.assertNotEqual(credentials_by_tag["trojan-8443"].get("password"), "TROJAN_ALICE_PASSWORD")
    self.assertNotEqual(credentials_by_tag["tuic-9443"].get("uuid"), "00000000-0000-4000-8000-000000000012")
    self.assertNotEqual(credentials_by_tag["tuic-9443"].get("password"), "TUIC_ALICE_PASSWORD")
    enabled_index = json.loads(index_path.read_text(encoding="utf-8"))
    alice_serialized = json.dumps(enabled_index["users"]["alice"])
    self.assertNotIn("BOB_PASSWORD", alice_serialized)
    self.assertNotIn("00000000-0000-4000-8000-000000000003", alice_serialized)
    self.assertNotIn("ACME_TEST_TOKEN_SECRET", alice_serialized)

    config_before_quota = config_path.read_bytes()
    quota = self._run(str(SB_SH), "users", "set-quota", "alice", "99", env=env)
    self.assertEqual(quota.returncode, 0, quota.stderr)
    self.assertEqual(config_path.read_bytes(), config_before_quota)
    self.assertEqual(json.loads(index_path.read_text(encoding="utf-8"))["users"]["alice"]["usage"]["quota_gb"], 99)

    added = self._run(str(SB_SH), "users", "add", "carol", env=env)
    self.assertEqual(added.returncode, 0, added.stderr)
    added_config = json.loads(config_path.read_text(encoding="utf-8"))
    self.assertTrue(all(
      any(entry["name"].endswith("@carol") for entry in inbound.get("users", []))
      for inbound in added_config["inbounds"]
    ))
    self.assertEqual(len(json.loads(index_path.read_text(encoding="utf-8"))["users"]["carol"]["inbounds"]), 5)

    refused_delete = self._run(str(SB_SH), "users", "delete", "carol", env=env)
    self.assertNotEqual(refused_delete.returncode, 0)
    self.assertIn("YES", refused_delete.stderr)

    deleted = self._run(str(SB_SH), "users", "delete", "carol", "YES", env=env)
    self.assertEqual(deleted.returncode, 0, deleted.stderr)
    deleted_config = json.loads(config_path.read_text(encoding="utf-8"))
    self.assertTrue(all(
      all(not entry["name"].endswith("@carol") for entry in inbound.get("users", []))
      for inbound in deleted_config["inbounds"]
    ))
    self.assertNotIn("carol", json.loads(index_path.read_text(encoding="utf-8"))["users"])

  def test_user_service_failure_restores_users_config_and_index(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    self._seed_managed_inbounds(config_path, meta_path)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    failure_marker = self.root / "service.failed"
    self._write_common_stubs(bin_dir, systemctl_body='''
case "${1:-}" in
  is-active) exit 0 ;;
  restart)
    if [[ ! -e "${SUBFLOW_TEST_SERVICE_FAILED}" ]]; then
      : >"${SUBFLOW_TEST_SERVICE_FAILED}"
      exit 1
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
''')
    env = self._common_env(
      bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir,
      extra={"SUBFLOW_TEST_SERVICE_FAILED": failure_marker.as_posix()},
    )
    before = {
      "users": users_path.read_bytes(),
      "config": config_path.read_bytes(),
      "index": index_path.read_bytes(),
    }

    result = self._run(str(SB_SH), "users", "disable", "alice", env=env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("已恢复旧状态", result.stderr)
    self.assertEqual(users_path.read_bytes(), before["users"])
    self.assertEqual(config_path.read_bytes(), before["config"])
    self.assertEqual(index_path.read_bytes(), before["index"])
    self.assertFalse(any(state_dir.glob(".txn.*")))

  def test_recover_restores_pending_transaction_and_rejects_bad_manifest(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)

    txn_dir = state_dir / ".txn.restore"
    backup_dir = txn_dir / "backup"
    backup_dir.mkdir(parents=True)
    (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (txn_dir / "recovery.manifest.json").write_text(json.dumps({
      "version": 1,
      "txn_dir": txn_dir.as_posix(),
      "state_dir": state_dir.as_posix(),
      "users_target": users_path.as_posix(),
      "index_target": index_path.as_posix(),
      "users_backup": "backup/users.json",
      "index_backup": "backup/subscriptions.json",
      "users_existed": True,
      "index_existed": True,
      "operation": "users-add",
      "username": "carol",
    }), encoding="utf-8")
    shutil.copy2(users_path, backup_dir / "users.json")
    shutil.copy2(index_path, backup_dir / "subscriptions.json")
    users_path.write_text(json.dumps({"schema_version": 1, "users": {"carol": {"enabled": False, "disabled_reason": "manual", "quota_gb": 9, "used_up_bytes": 0, "used_down_bytes": 0, "manual_added_bytes": 0, "last_live_up_bytes": 0, "last_live_down_bytes": 0, "last_reset_period": "", "reset_day": 0, "expire_at": "0", "allow_all_nodes": True, "nodes": []}}}), encoding="utf-8")
    index_path.write_text(json.dumps({"schema_version": 1, "users": {"carol": {"usage": {}, "inbounds": [], "meta": {}}}}), encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("alice", json.loads(users_path.read_text(encoding="utf-8"))["users"])
    self.assertNotIn("carol", json.loads(users_path.read_text(encoding="utf-8"))["users"])
    self.assertFalse(txn_dir.exists())

    bad_txn = state_dir / ".txn.bad"
    bad_txn.mkdir(parents=True)
    (bad_txn / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (bad_txn / "recovery.manifest.json").write_text(json.dumps({
      "version": 1,
      "txn_dir": bad_txn.as_posix(),
      "state_dir": state_dir.as_posix(),
      "users_target": (self.root / "outside-users.json").as_posix(),
      "index_target": index_path.as_posix(),
      "users_backup": "backup/users.json",
      "index_backup": "backup/subscriptions.json",
      "users_existed": False,
      "index_existed": False,
      "operation": "users-add",
      "username": "evil",
    }), encoding="utf-8")
    sentinel = self.root / "outside-users.json"
    sentinel.write_text("keep\n", encoding="utf-8")

    bad = self._run(str(SB_SH), "recover", env=env)
    self.assertNotEqual(bad.returncode, 0)
    self.assertTrue(sentinel.exists())
    self.assertIn("非法", bad.stderr)

  def test_recover_restores_v2_user_config_transaction(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    self._seed_managed_inbounds(config_path, meta_path)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)
    service_target = Path(env["SUBFLOW_SYSTEMD_UNIT_PATH"])
    original = {
      "users": users_path.read_bytes(),
      "config": config_path.read_bytes(),
      "index": index_path.read_bytes(),
    }

    txn_dir = state_dir / ".txn.userv2"
    backup_dir = txn_dir / "backup"
    backup_dir.mkdir(parents=True)
    (backup_dir / "users.json").write_bytes(original["users"])
    (backup_dir / "config.json").write_bytes(original["config"])
    (backup_dir / "subscriptions.json").write_bytes(original["index"])
    (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (txn_dir / "recovery.manifest.json").write_text(json.dumps({
      "version": 2,
      "kind": "user-config",
      "txn_dir": txn_dir.as_posix(),
      "state_dir": state_dir.as_posix(),
      "users_target": users_path.as_posix(),
      "index_target": index_path.as_posix(),
      "config_target": config_path.as_posix(),
      "service_target": service_target.as_posix(),
      "init": "systemd",
      "operation": "disable",
      "username": "alice",
      "users_backup": "backup/users.json",
      "index_backup": "backup/subscriptions.json",
      "config_backup": "backup/config.json",
      "users_existed": True,
      "index_existed": True,
      "config_existed": True,
      "config_changed": True,
      "service_existed": True,
      "service_was_active": True,
    }), encoding="utf-8")
    users_path.write_text('{"schema_version":1,"users":{}}\n', encoding="utf-8")
    config_path.write_text('{"inbounds":[]}\n', encoding="utf-8")
    index_path.write_text('{"schema_version":1,"users":{}}\n', encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(users_path.read_bytes(), original["users"])
    self.assertEqual(config_path.read_bytes(), original["config"])
    self.assertEqual(index_path.read_bytes(), original["index"])
    self.assertFalse(txn_dir.exists())

  def test_lock_failure_and_safe_jq_usage_are_enforced(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir, flock_body="exit 1")
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)

    result = self._run(str(SB_SH), "users", "add", "carol", "--quota", "1", "--reset-day", "0", "--expire", "0", env=env)
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("全局锁", result.stderr)

    users_source = (REPO_ROOT / "vps" / "singbox-cleanroom" / "lib" / "85_users.sh").read_text(encoding="utf-8")
    lock_source = (REPO_ROOT / "vps" / "singbox-cleanroom" / "lib" / "30_lock.sh").read_text(encoding="utf-8")
    self.assertIn("jq --arg", users_source)
    self.assertIn("--argjson", users_source)
    self.assertNotIn("eval(", users_source)
    self.assertNotRegex(users_source, r"(?m)^\s*source\s")
    self.assertNotIn("exec {SUBFLOW_LOCK_FD}>&- 2>/dev/null", lock_source)
    self.assertIn("{ exec {SUBFLOW_LOCK_FD}>&-; } 2>/dev/null", lock_source)

  def test_recover_rejects_missing_backup_without_partial_restore(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)

    txn_dir = state_dir / ".txn.missing"
    backup_dir = txn_dir / "backup"
    backup_dir.mkdir(parents=True)
    (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (txn_dir / "recovery.manifest.json").write_text(json.dumps({
      "version": 1,
      "txn_dir": txn_dir.as_posix(),
      "state_dir": state_dir.as_posix(),
      "users_target": users_path.as_posix(),
      "index_target": index_path.as_posix(),
      "users_backup": "backup/users.json",
      "index_backup": "backup/subscriptions.json",
      "users_existed": True,
      "index_existed": True,
      "operation": "users-add",
      "username": "carol",
    }), encoding="utf-8")
    shutil.copy2(users_path, backup_dir / "users.json")

    current_users = {"schema_version": 1, "users": {"current": {"enabled": True}}}
    current_index = {"schema_version": 1, "users": {"current": {"usage": {}}}}
    users_path.write_text(json.dumps(current_users), encoding="utf-8")
    index_path.write_text(json.dumps(current_index), encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("缺少可信事务备份", result.stderr)
    self.assertEqual(json.loads(users_path.read_text(encoding="utf-8")), current_users)
    self.assertEqual(json.loads(index_path.read_text(encoding="utf-8")), current_index)
    self.assertTrue((txn_dir / "recovery.pending").exists())

  def test_recover_rejects_multiple_pending_transactions(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)

    for name in (".txn.first", ".txn.second"):
      txn_dir = state_dir / name
      txn_dir.mkdir()
      (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("多个未完成事务", result.stderr)
    self.assertNotIn("没有待恢复事务", result.stdout)

  def test_missing_backend_cannot_write_in_conditional_context(self):
    self._build()
    config_path, users_path, meta_path, index_path, state_dir, secrets_dir = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_common_stubs(bin_dir)
    env = self._common_env(bin_dir, config_path, users_path, meta_path, index_path, state_dir, secrets_dir)
    before_users = users_path.read_text(encoding="utf-8")
    before_index = index_path.read_text(encoding="utf-8")
    command = (
      f'source "{SB_SH.as_posix()}"; '
      'subflow_has_cmd() { if [[ "$1" == "jq" ]]; then return 1; fi; command -v "$1" >/dev/null 2>&1; }; '
      'if main users add carol --quota 1 --reset-day 0 --expire 0; then exit 0; else exit 42; fi'
    )

    result = self._run("-c", command, env=env)

    self.assertEqual(result.returncode, 42)
    self.assertIn("缺少必要命令: jq", result.stderr)
    self.assertEqual(users_path.read_text(encoding="utf-8"), before_users)
    self.assertEqual(index_path.read_text(encoding="utf-8"), before_index)
