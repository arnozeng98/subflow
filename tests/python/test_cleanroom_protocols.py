import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SH = REPO_ROOT / "vps" / "singbox-cleanroom" / "build.sh"
SB_SH = REPO_ROOT / "vps" / "singbox-cleanroom" / "sb.sh"
BASH = shutil.which("bash") or "bash"
PYTHON = Path(sys.executable)
PRIVATE_KEY = "A" * 43
PUBLIC_KEY = "B" * 43


class CleanroomProtocolTests(unittest.TestCase):
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

  def _fixture(self):
    paths = {
      "config": self.root / "config.json",
      "users": self.root / "users.json",
      "meta": self.root / "meta.json",
      "index": self.root / "subscriptions.json",
      "state": self.root / "state",
      "secrets": self.root / "state" / "secrets",
      "lock": self.root / "subflow.lock",
      "unit": self.root / "systemd" / "sing-box.service",
      "openrc": self.root / "openrc" / "sing-box",
      "service_state": self.root / "service.state",
      "service_failed": self.root / "service.failed",
    }
    paths["state"].mkdir(parents=True)
    paths["secrets"].mkdir()
    paths["config"].write_text(json.dumps({
      "log": {"level": "info"},
      "inbounds": [],
      "outbounds": [{"type": "direct", "tag": "direct"}],
    }), encoding="utf-8")
    paths["users"].write_text(json.dumps({
      "schema_version": 1,
      "users": {
        "admin": self._user(),
        "alice": self._user(),
        "bob": self._user(allow_all_nodes=False),
      },
    }), encoding="utf-8")
    paths["meta"].write_text("{}\n", encoding="utf-8")
    paths["index"].write_text(json.dumps({"schema_version": 1, "users": {}}), encoding="utf-8")
    return paths

  @staticmethod
  def _user(*, allow_all_nodes=True):
    return {
      "enabled": True,
      "disabled_reason": None,
      "quota_gb": 0,
      "used_up_bytes": 0,
      "used_down_bytes": 0,
      "manual_added_bytes": 0,
      "last_live_up_bytes": 0,
      "last_live_down_bytes": 0,
      "last_reset_period": "",
      "reset_day": 0,
      "expire_at": "0",
      "allow_all_nodes": allow_all_nodes,
      "nodes": [],
    }

  def _write_jq_stub(self, bin_dir: Path):
    helper = self.root / "jq_protocol_stub.py"
    helper.write_text("""import json
import sys
from pathlib import Path

args = sys.argv[1:]
argfiles = {}
flags = set()
positionals = []
index = 0
while index < len(args):
  token = args[index]
  if token == '--argfile':
    argfiles[args[index + 1]] = args[index + 2]
    index += 3
    continue
  if token.startswith('-'):
    flags.update(token[1:])
    index += 1
    continue
  positionals.append(token)
  index += 1

query = ' '.join((positionals[0] if positionals else '').split())

def load(path):
  return json.loads(Path(path).read_text(encoding='utf-8'))

def owner(name):
  return name.split('@', 1)[1] if '@' in name else 'admin'

if 'n' in flags and argfiles:
  config = load(argfiles['config'])
  users = load(argfiles['users'])
  meta = load(argfiles['meta'])
  output = {'schema_version': 1, 'users': {}}
  for username, user in sorted(users['users'].items()):
    projected_inbounds = []
    projected_meta = {}
    for inbound in config.get('inbounds', []):
      selected_users = []
      for entry in inbound.get('users', []):
        if owner(entry.get('name', '')) != username:
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
      transport = inbound.get('transport')
      if isinstance(transport, dict):
        selected_transport = {field: transport[field] for field in ('type', 'path') if transport.get(field) is not None}
        if selected_transport:
          selected_inbound['transport'] = selected_transport
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
    usage = dict(user)
    for field, default in {
      'enabled': True,
      'disabled_reason': None,
      'quota_gb': 0,
      'used_up_bytes': 0,
      'used_down_bytes': 0,
      'manual_added_bytes': 0,
      'last_live_up_bytes': 0,
      'last_live_down_bytes': 0,
      'last_reset_period': '',
      'reset_day': 0,
      'expire_at': '0',
      'allow_all_nodes': True,
      'nodes': [],
    }.items():
      usage.setdefault(field, default)
    output['users'][username] = {
      'usage': usage,
      'inbounds': projected_inbounds,
      'meta': projected_meta,
    }
  print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
  sys.exit(0)

input_file = next((item for item in reversed(positionals[1:]) if Path(item).is_file()), None)
if input_file is None:
  sys.exit(1)
data = load(input_file)
if query == '.':
  sys.exit(0)
if query == 'type == "object"':
  sys.exit(0 if isinstance(data, dict) else 1)
if query == 'type == "object" and .schema_version == 1 and (.users | type == "object")':
  sys.exit(0 if isinstance(data, dict) and data.get('schema_version') == 1 and isinstance(data.get('users'), dict) else 1)
if query == 'type == "object" and (.inbounds | type == "array")':
  sys.exit(0 if isinstance(data, dict) and isinstance(data.get('inbounds'), list) else 1)
sys.exit(1)
""", encoding="utf-8")
    self._write_stub(bin_dir, "jq", f'exec "{PYTHON.as_posix()}" "{helper.as_posix()}" "$@"')

  def _write_stubs(self, bin_dir: Path):
    self._write_stub(bin_dir, "flock", "exit 0")
    self._write_stub(bin_dir, "python3", f'exec "{PYTHON.as_posix()}" "$@"')
    self._write_stub(bin_dir, "openssl", '[[ "${1:-}" == "rand" ]] && printf "0123456789abcdef\\n"')
    self._write_stub(bin_dir, "sing-box", f'''
case "${{1:-}}" in
  version) printf 'sing-box version 9.9.9\\nwith_v2ray_api with_wireguard with_acme\\n' ;;
  generate)
    [[ "${{2:-}}" == "reality-keypair" ]] || exit 1
    printf 'PrivateKey: {PRIVATE_KEY}\\nPublicKey: {PUBLIC_KEY}\\n'
    ;;
  check)
    [[ -z "${{SUBFLOW_TEST_CHECK_FAIL:-}}" ]] || exit 1
    config="${{3:-}}"
    exec "{PYTHON.as_posix()}" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$config"
    ;;
  *) exit 0 ;;
esac
''')
    self._write_stub(bin_dir, "systemctl", '''
command_name="${1:-}"
case "$command_name" in
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
    self._write_jq_stub(bin_dir)

  def _env(self, bin_dir, paths, *, extra=None):
    env = os.environ.copy()
    env.update({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "LC_ALL": "C",
      "SUBFLOW_INIT": "systemd",
      "SUBFLOW_CONFIG_PATH": paths["config"].as_posix(),
      "SUBFLOW_USERS_PATH": paths["users"].as_posix(),
      "SUBFLOW_META_PATH": paths["meta"].as_posix(),
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH": paths["index"].as_posix(),
      "SUBFLOW_STATE_DIR": paths["state"].as_posix(),
      "SUBFLOW_SECRETS_DIR": paths["secrets"].as_posix(),
      "SUBFLOW_LOCK_PATH": paths["lock"].as_posix(),
      "SUBFLOW_SINGBOX_BIN": (bin_dir / "sing-box").as_posix(),
      "SUBFLOW_SYSTEMD_UNIT_PATH": paths["unit"].as_posix(),
      "SUBFLOW_OPENRC_SERVICE_PATH": paths["openrc"].as_posix(),
      "SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH": (paths["secrets"] / "cloudflare-acme.json").as_posix(),
      "SUBFLOW_ACME_DATA_DIR": (paths["secrets"] / "acme").as_posix(),
      "SUBFLOW_TEST_SERVICE_STATE": paths["service_state"].as_posix(),
      "SUBFLOW_TEST_SERVICE_FAILED": paths["service_failed"].as_posix(),
    })
    if extra:
      env.update(extra)
    return env

  def _add(self, env):
    return self._run(
      str(SB_SH),
      "protocols",
      "add",
      "vless-reality",
      "--tag",
      "reality-443",
      "--port",
      "443",
      "--server-name",
      "www.example.com",
      "--handshake-server",
      "www.example.com",
      env=env,
    )

  def test_vless_reality_add_update_list_and_delete(self):
    self._build()
    paths = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths)

    added = self._add(env)
    self.assertEqual(added.returncode, 0, added.stderr)

    config = json.loads(paths["config"].read_text(encoding="utf-8"))
    inbound = config["inbounds"][0]
    self.assertEqual(inbound["type"], "vless")
    self.assertEqual(inbound["tag"], "reality-443")
    self.assertEqual(inbound["listen_port"], 443)
    self.assertEqual(inbound["tls"]["reality"]["private_key"], PRIVATE_KEY)
    self.assertEqual(inbound["tls"]["reality"]["short_id"], ["0123456789abcdef"])
    names = [entry["name"] for entry in inbound["users"]]
    self.assertEqual(names, ["reality-443@admin", "reality-443@alice"])
    self.assertTrue(all(uuid.UUID(entry["uuid"]) for entry in inbound["users"]))
    original_credentials = {entry["name"]: entry["uuid"] for entry in inbound["users"]}

    meta = json.loads(paths["meta"].read_text(encoding="utf-8"))
    self.assertEqual(meta, {"reality-443": {"public_key": PUBLIC_KEY}})
    index = json.loads(paths["index"].read_text(encoding="utf-8"))
    self.assertEqual(index["users"]["alice"]["meta"], {"reality-443": {"public_key": PUBLIC_KEY}})
    self.assertEqual(index["users"]["bob"]["inbounds"], [])
    serialized_index = json.dumps(index)
    self.assertNotIn(PRIVATE_KEY, serialized_index)
    self.assertNotIn("handshake", serialized_index)
    self.assertNotIn(original_credentials["reality-443@admin"], json.dumps(index["users"]["alice"]))

    listing = self._run(str(SB_SH), "protocols", "list", env=env)
    self.assertEqual(listing.returncode, 0, listing.stderr)
    self.assertIn("reality-443 | vless-reality | 443 | 2", listing.stdout)

    updated = self._run(
      str(SB_SH), "protocols", "update", "reality-443",
      "--port", "8443",
      "--server-name", "cdn.example.com",
      "--handshake-server", "origin.example.com",
      "--handshake-port", "8443",
      env=env,
    )
    self.assertEqual(updated.returncode, 0, updated.stderr)
    updated_inbound = json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"][0]
    self.assertEqual(updated_inbound["listen_port"], 8443)
    self.assertEqual(updated_inbound["tls"]["server_name"], "cdn.example.com")
    self.assertEqual(updated_inbound["tls"]["reality"]["handshake"], {
      "server": "origin.example.com",
      "server_port": 8443,
    })
    self.assertEqual(updated_inbound["tls"]["reality"]["private_key"], PRIVATE_KEY)
    self.assertEqual(
      {entry["name"]: entry["uuid"] for entry in updated_inbound["users"]},
      original_credentials,
    )

    refused_delete = self._run(str(SB_SH), "protocols", "delete", "reality-443", env=env)
    self.assertNotEqual(refused_delete.returncode, 0)
    self.assertIn("YES", refused_delete.stderr)

    deleted = self._run(str(SB_SH), "protocols", "delete", "reality-443", "YES", env=env)
    self.assertEqual(deleted.returncode, 0, deleted.stderr)
    self.assertEqual(json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"], [])
    self.assertEqual(json.loads(paths["meta"].read_text(encoding="utf-8")), {})
    deleted_index = json.loads(paths["index"].read_text(encoding="utf-8"))
    self.assertTrue(all(not record["inbounds"] for record in deleted_index["users"].values()))
    self.assertTrue(paths["service_state"].exists())
    self.assertFalse(any(paths["state"].glob(".txn.*")))

  def test_invalid_duplicate_and_failed_candidate_do_not_write(self):
    self._build()
    paths = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths)
    original = tuple(paths[key].read_text(encoding="utf-8") for key in ("config", "meta", "index"))

    invalid = self._run(
      str(SB_SH), "protocols", "add", "vless-reality",
      "--tag", "bad/tag", "--server-name", "not-a-domain",
      env=env,
    )
    self.assertNotEqual(invalid.returncode, 0)
    self.assertEqual(tuple(paths[key].read_text(encoding="utf-8") for key in ("config", "meta", "index")), original)

    env["SUBFLOW_TEST_CHECK_FAIL"] = "1"
    failed_check = self._add(env)
    self.assertNotEqual(failed_check.returncode, 0)
    self.assertIn("候选协议配置校验失败", failed_check.stderr)
    self.assertEqual(tuple(paths[key].read_text(encoding="utf-8") for key in ("config", "meta", "index")), original)
    self.assertFalse(any(paths["state"].glob(".txn.*")))

  def test_shadowsocks_2022_add_update_and_delete(self):
    self._build()
    paths = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths)

    invalid = self._run(
      str(SB_SH), "protocols", "add", "shadowsocks-2022",
      "--tag", "ss-8388", "--method", "aes-128-gcm",
      env=env,
    )
    self.assertNotEqual(invalid.returncode, 0)
    self.assertIn("不支持", invalid.stderr)

    added = self._run(
      str(SB_SH), "protocols", "add", "shadowsocks-2022",
      "--tag", "ss-8388", "--port", "8388",
      "--method", "2022-blake3-aes-128-gcm",
      env=env,
    )
    self.assertEqual(added.returncode, 0, added.stderr)

    inbound = json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"][0]
    self.assertEqual(inbound["type"], "shadowsocks")
    self.assertEqual(inbound["network"], "tcp")
    self.assertEqual(inbound["method"], "2022-blake3-aes-128-gcm")
    self.assertEqual(len(base64.b64decode(inbound["password"])), 16)
    self.assertEqual([entry["name"] for entry in inbound["users"]], ["ss-8388@admin", "ss-8388@alice"])
    self.assertTrue(all(len(base64.b64decode(entry["password"])) == 16 for entry in inbound["users"]))
    original_server_password = inbound["password"]
    original_user_passwords = {entry["name"]: entry["password"] for entry in inbound["users"]}

    index = json.loads(paths["index"].read_text(encoding="utf-8"))
    alice_inbound = index["users"]["alice"]["inbounds"][0]
    self.assertEqual(alice_inbound["password"], original_server_password)
    self.assertEqual(alice_inbound["users"], [{
      "name": "ss-8388@alice",
      "username": "alice",
      "password": original_user_passwords["ss-8388@alice"],
    }])
    self.assertNotIn(original_user_passwords["ss-8388@admin"], json.dumps(index["users"]["alice"]))
    self.assertEqual(index["users"]["bob"]["inbounds"], [])

    updated = self._run(
      str(SB_SH), "protocols", "update", "ss-8388", "--port", "9443", env=env,
    )
    self.assertEqual(updated.returncode, 0, updated.stderr)
    updated_inbound = json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"][0]
    self.assertEqual(updated_inbound["listen_port"], 9443)
    self.assertEqual(updated_inbound["password"], original_server_password)
    self.assertEqual(
      {entry["name"]: entry["password"] for entry in updated_inbound["users"]},
      original_user_passwords,
    )

    deleted = self._run(str(SB_SH), "protocols", "delete", "ss-8388", "YES", env=env)
    self.assertEqual(deleted.returncode, 0, deleted.stderr)
    self.assertEqual(json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"], [])
    self.assertTrue(all(not record["inbounds"] for record in json.loads(paths["index"].read_text(encoding="utf-8"))["users"].values()))

  def test_acme_tls_protocols_are_isolated_and_preserve_credentials_on_update(self):
    self._build()
    paths = self._fixture()
    api_token = "API_" + "T" * 36
    zone_token = "ZONE_" + "Z" * 35
    secret_path = paths["secrets"] / "cloudflare-acme.json"
    secret_path.write_text(json.dumps({
      "api_token": api_token,
      "zone_token": zone_token,
    }), encoding="utf-8")
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths)

    protocols = (
      ("anytls", "anytls-7443", "7443", "any.example.com"),
      ("trojan", "trojan-8443", "8443", "trojan.example.com"),
      ("tuic", "tuic-9443", "9443", "tuic.example.com"),
    )
    for protocol, tag, port, domain in protocols:
      result = self._run(
        str(SB_SH), "protocols", "add", protocol,
        "--tag", tag,
        "--port", port,
        "--domain", domain,
        "--email", "ops@example.com",
        env=env,
      )
      self.assertEqual(result.returncode, 0, result.stderr)

    config = json.loads(paths["config"].read_text(encoding="utf-8"))
    by_tag = {inbound["tag"]: inbound for inbound in config["inbounds"]}
    for protocol, tag, port, domain in protocols:
      inbound = by_tag[tag]
      self.assertEqual(inbound["type"], protocol)
      self.assertEqual(inbound["listen_port"], int(port))
      self.assertEqual(inbound["tls"]["server_name"], domain)
      self.assertEqual(inbound["tls"]["acme"]["dns01_challenge"], {
        "provider": "cloudflare",
        "api_token": api_token,
        "zone_token": zone_token,
      })
      self.assertEqual([entry["name"] for entry in inbound["users"]], [f"{tag}@admin", f"{tag}@alice"])
      self.assertTrue(all(entry.get("password") for entry in inbound["users"]))
    self.assertTrue(all(entry.get("uuid") for entry in by_tag["tuic-9443"]["users"]))
    self.assertFalse(by_tag["tuic-9443"]["zero_rtt_handshake"])

    index = json.loads(paths["index"].read_text(encoding="utf-8"))
    serialized_index = json.dumps(index)
    self.assertNotIn(api_token, serialized_index)
    self.assertNotIn(zone_token, serialized_index)
    self.assertNotIn("acme", serialized_index)
    self.assertEqual(index["users"]["bob"]["inbounds"], [])
    alice_serialized = json.dumps(index["users"]["alice"])
    self.assertNotIn("@admin", alice_serialized)

    anytls_users = json.loads(json.dumps(by_tag["anytls-7443"]["users"]))
    next_api_token = "NEXT_" + "N" * 35
    secret_path.write_text(json.dumps({"api_token": next_api_token}), encoding="utf-8")
    updated = self._run(
      str(SB_SH), "protocols", "update", "anytls-7443",
      "--port", "10443",
      "--domain", "next.example.com",
      "--email", "next@example.com",
      env=env,
    )
    self.assertEqual(updated.returncode, 0, updated.stderr)
    updated_anytls = next(
      inbound
      for inbound in json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"]
      if inbound["tag"] == "anytls-7443"
    )
    self.assertEqual(updated_anytls["users"], anytls_users)
    self.assertEqual(updated_anytls["listen_port"], 10443)
    self.assertEqual(updated_anytls["tls"]["server_name"], "next.example.com")
    self.assertEqual(updated_anytls["tls"]["acme"]["dns01_challenge"], {
      "provider": "cloudflare",
      "api_token": next_api_token,
    })

    secret_path.unlink()
    deleted = self._run(str(SB_SH), "protocols", "delete", "tuic-9443", "YES", env=env)
    self.assertEqual(deleted.returncode, 0, deleted.stderr)
    self.assertNotIn(
      "tuic-9443",
      {inbound["tag"] for inbound in json.loads(paths["config"].read_text(encoding="utf-8"))["inbounds"]},
    )

  def test_tls_protocol_add_requires_acme_secret(self):
    self._build()
    paths = self._fixture()
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    missing_secret = paths["secrets"] / "missing-acme.json"
    env = self._env(bin_dir, paths)
    env["SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH"] = missing_secret.as_posix()
    before = paths["config"].read_bytes()

    result = self._run(
      str(SB_SH), "protocols", "add", "anytls",
      "--tag", "anytls-443",
      "--domain", "any.example.com",
      "--email", "ops@example.com",
      env=env,
    )

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("ACME", result.stderr)
    self.assertEqual(paths["config"].read_bytes(), before)

  def test_service_failure_rolls_back_all_protocol_files(self):
    self._build()
    paths = self._fixture()
    paths["unit"].parent.mkdir(parents=True)
    paths["unit"].write_text("old service\n", encoding="utf-8")
    paths["service_state"].write_text("active\n", encoding="utf-8")
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, extra={"SUBFLOW_TEST_FAIL_RESTART_ONCE": "1"})
    before = {key: paths[key].read_bytes() for key in ("config", "meta", "index", "unit")}

    result = self._add(env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("已恢复旧配置", result.stderr)
    self.assertEqual({key: paths[key].read_bytes() for key in before}, before)
    self.assertTrue(paths["service_state"].exists())
    self.assertFalse(any(paths["state"].glob(".txn.*")))

  def test_recover_restores_interrupted_protocol_transaction(self):
    self._build()
    paths = self._fixture()
    paths["unit"].parent.mkdir(parents=True)
    paths["unit"].write_text("old service\n", encoding="utf-8")
    paths["service_state"].write_text("active\n", encoding="utf-8")
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths)
    old = {key: paths[key].read_bytes() for key in ("config", "meta", "index", "unit")}

    txn_dir = paths["state"] / ".txn.crash"
    backup_dir = txn_dir / "backup"
    backup_dir.mkdir(parents=True)
    for key, name in (("config", "config.json"), ("meta", "meta.json"), ("index", "subscriptions.json"), ("unit", "service")):
      (backup_dir / name).write_bytes(old[key])
    (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (txn_dir / "protocol.manifest.json").write_text(json.dumps({
      "version": 1,
      "kind": "protocol-config",
      "txn_dir": txn_dir.as_posix(),
      "state_dir": paths["state"].as_posix(),
      "config_target": paths["config"].as_posix(),
      "meta_target": paths["meta"].as_posix(),
      "index_target": paths["index"].as_posix(),
      "service_target": paths["unit"].as_posix(),
      "operation": "add",
      "tag": "reality-443",
      "init": "systemd",
      "config_backup": "backup/config.json",
      "meta_backup": "backup/meta.json",
      "index_backup": "backup/subscriptions.json",
      "service_backup": "backup/service",
      "config_existed": True,
      "meta_existed": True,
      "index_existed": True,
      "service_existed": True,
      "service_was_active": True,
    }), encoding="utf-8")
    paths["config"].write_text('{"inbounds":[{"tag":"new"}]}\n', encoding="utf-8")
    paths["meta"].write_text('{"new":{}}\n', encoding="utf-8")
    paths["index"].write_text('{"schema_version":1,"users":{"new":{}}}\n', encoding="utf-8")
    paths["unit"].write_text("new service\n", encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual({key: paths[key].read_bytes() for key in old}, old)
    self.assertFalse(txn_dir.exists())


if __name__ == "__main__":
  unittest.main()