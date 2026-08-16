import hashlib
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


class CleanroomInstallTests(unittest.TestCase):
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

  def _candidate(self, version="9.9.9", *, include_acme=True):
    candidate = self.root / f"sing-box-{version}"
    tags = ["with_v2ray_api", "with_wireguard"]
    if include_acme:
      tags.append("with_acme")
    candidate.write_text(
      "#!/usr/bin/env bash\n"
      "set -Eeuo pipefail\n"
      f"if [[ \"${{1:-}}\" == \"version\" ]]; then printf 'sing-box version {version}\\n{' '.join(tags)}\\n'; exit 0; fi\n"
      "if [[ \"${1:-}\" == \"check\" ]]; then exit 0; fi\n"
      "if [[ \"${1:-}\" == \"run\" ]]; then exit 0; fi\n"
      "exit 1\n",
      encoding="utf-8",
    )
    candidate.chmod(0o755)
    return candidate

  def _manifest(self, candidate: Path, version="9.9.9", *, sha256=None):
    manifest = self.root / "releases.json"
    digest = sha256 or hashlib.sha256(candidate.read_bytes()).hexdigest()
    manifest.write_text(json.dumps({
      "schema_version": 1,
      "repository": "example/subflow",
      "latest": version,
      "releases": {
        version: {
          "upstream_repository": "SagerNet/sing-box",
          "upstream_tag": f"v{version}",
          "assets": {
            "amd64": {"name": "sing-box-linux-amd64", "sha256": digest},
            "arm64": {"name": "sing-box-linux-arm64", "sha256": digest},
          },
        },
      },
    }), encoding="utf-8")
    return manifest

  def _paths(self):
    paths = {
      "config": self.root / "config.json",
      "users": self.root / "users.json",
      "meta": self.root / "meta.json",
      "index": self.root / "subscriptions.json",
      "state": self.root / "state",
      "secrets": self.root / "state" / "secrets",
      "binary": self.root / "installed" / "sing-box",
      "stamp": self.root / "state" / ".installed-release",
      "store": self.root / "versions",
      "manager": self.root / "root" / "sb.sh",
      "shortcut": self.root / "installed" / "s",
      "unit": self.root / "systemd" / "sing-box.service",
      "openrc": self.root / "openrc" / "sing-box",
      "lock": self.root / "subflow.lock",
      "service_state": self.root / "service.state",
      "service_failed": self.root / "service.failed",
      "curl_log": self.root / "curl.log",
    }
    paths["state"].mkdir(parents=True)
    paths["secrets"].mkdir()
    paths["config"].write_text(json.dumps({"inbounds": []}), encoding="utf-8")
    paths["users"].write_text(json.dumps({"schema_version": 1, "users": {}}), encoding="utf-8")
    paths["meta"].write_text("{}\n", encoding="utf-8")
    paths["index"].write_text(json.dumps({"schema_version": 1, "users": {}}), encoding="utf-8")
    return paths

  def _write_jq_stub(self, bin_dir: Path):
    helper = self.root / "jq_install_stub.py"
    helper.write_text("""import json
import sys
from pathlib import Path

args = sys.argv[1:]
named = {'arg': {}, 'argjson': {}}
flags = set()
positionals = []
index = 0
while index < len(args):
  token = args[index]
  if token in ('--arg', '--argjson'):
    named[token[2:]][args[index + 1]] = args[index + 2]
    index += 3
    continue
  if token.startswith('-'):
    flags.update(token[1:])
    index += 1
    continue
  positionals.append(token)
  index += 1

query = ' '.join((positionals[0] if positionals else '').split())

def emit(value):
  if isinstance(value, bool):
    print('true' if value else 'false')
  elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
  else:
    print(value)

if 'n' in flags:
  if 'kind: "sing-box-install"' not in query:
    sys.exit(1)
  output = {
    'version': 1,
    'kind': 'sing-box-install',
    'txn_dir': named['arg']['txn_dir'],
    'state_dir': named['arg']['state_dir'],
    'binary_target': named['arg']['binary_target'],
    'stamp_target': named['arg']['stamp_target'],
    'service_target': named['arg']['service_target'],
    'init': named['arg']['init'],
    'binary_backup': 'backup/sing-box',
    'stamp_backup': 'backup/installed-release',
    'service_backup': 'backup/service',
    'binary_existed': named['argjson']['binary_existed'] == 'true',
    'stamp_existed': named['argjson']['stamp_existed'] == 'true',
    'service_changed': named['argjson']['service_changed'] == 'true',
    'service_existed': named['argjson']['service_existed'] == 'true',
    'service_was_active': named['argjson']['service_was_active'] == 'true',
  }
  emit(output)
  sys.exit(0)

input_file = next((item for item in reversed(positionals[1:]) if Path(item).is_file()), None)
if input_file:
  data = json.loads(Path(input_file).read_text(encoding='utf-8'))
else:
  data = json.load(sys.stdin)

if query == '.':
  sys.exit(0)
if query == 'type == "object"':
  sys.exit(0 if isinstance(data, dict) else 1)
if '.schema_version == 1' in query and '.releases[$latest]' in query:
  valid = (
    isinstance(data, dict)
    and data.get('schema_version') == 1
    and isinstance(data.get('repository'), str)
    and isinstance(data.get('latest'), str)
    and isinstance(data.get('releases'), dict)
    and isinstance(data['releases'].get(data['latest']), dict)
  )
  sys.exit(0 if valid else 1)
if query == '.latest':
  emit(data['latest'])
  sys.exit(0)
if query == '.repository':
  emit(data['repository'])
  sys.exit(0)
if query == '.releases[$version].assets[$arch][$field] // empty':
  value = data.get('releases', {}).get(named['arg']['version'], {}).get('assets', {}).get(named['arg']['arch'], {}).get(named['arg']['field'])
  if value in (None, ''):
    sys.exit(1)
  emit(value)
  sys.exit(0)
if query.startswith('type == "object" and .version == 1 and .kind == "sing-box-install"'):
  valid = (
    data.get('version') == 1
    and data.get('kind') == 'sing-box-install'
    and data.get('txn_dir') == named['arg']['txn_dir']
    and data.get('state_dir') == named['arg']['state_dir']
    and data.get('binary_target') == named['arg']['binary_target']
    and data.get('stamp_target') == named['arg']['stamp_target']
    and data.get('init') in ('systemd', 'openrc')
    and all(type(data.get(field)) is bool for field in ('binary_existed', 'stamp_existed', 'service_changed', 'service_existed', 'service_was_active'))
  )
  sys.exit(0 if valid else 1)
if query.startswith('.') and query[1:] in data:
  emit(data[query[1:]])
  sys.exit(0)
sys.exit(1)
""", encoding="utf-8")
    self._write_stub(bin_dir, "jq", f'exec "{PYTHON.as_posix()}" "{helper.as_posix()}" "$@"')

  def _write_stubs(self, bin_dir: Path):
    self._write_stub(bin_dir, "id", '[[ "${1:-}" == "-u" ]] && printf "0\\n"')
    self._write_stub(bin_dir, "uname", '[[ "${1:-}" == "-m" ]] && printf "x86_64\\n"')
    self._write_stub(bin_dir, "apt-get", "exit 0")
    self._write_stub(bin_dir, "flock", "exit 0")
    self._write_stub(bin_dir, "curl", '''
output=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "${SUBFLOW_TEST_ASSET}" >"${SUBFLOW_TEST_CURL_LOG}"
cp "${SUBFLOW_TEST_ASSET}" "$output"
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
    self._write_stub(bin_dir, "rc-service", '''
command_name="${2:-}"
case "$command_name" in
  status) [[ -f "${SUBFLOW_TEST_SERVICE_STATE}" ]] ;;
  restart)
    if [[ -n "${SUBFLOW_TEST_FAIL_RESTART_ONCE:-}" && ! -e "${SUBFLOW_TEST_SERVICE_FAILED}" ]]; then
      : >"${SUBFLOW_TEST_SERVICE_FAILED}"
      exit 1
    fi
    : >"${SUBFLOW_TEST_SERVICE_STATE}"
    ;;
  start) : >"${SUBFLOW_TEST_SERVICE_STATE}" ;;
  stop) rm -f "${SUBFLOW_TEST_SERVICE_STATE}" ;;
  *) exit 0 ;;
esac
''')
    self._write_stub(bin_dir, "rc-update", "exit 0")
    self._write_jq_stub(bin_dir)

  def _env(self, bin_dir, paths, manifest, candidate, *, extra=None):
    env = os.environ.copy()
    env.update({
      "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
      "INVOCATION_ID": "1",
      "LC_ALL": "C",
      "SUBFLOW_CONFIG_PATH": paths["config"].as_posix(),
      "SUBFLOW_USERS_PATH": paths["users"].as_posix(),
      "SUBFLOW_META_PATH": paths["meta"].as_posix(),
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH": paths["index"].as_posix(),
      "SUBFLOW_STATE_DIR": paths["state"].as_posix(),
      "SUBFLOW_SECRETS_DIR": paths["secrets"].as_posix(),
      "SUBFLOW_LOCK_PATH": paths["lock"].as_posix(),
      "SUBFLOW_SINGBOX_BIN": paths["binary"].as_posix(),
      "SUBFLOW_VERSION_STAMP": paths["stamp"].as_posix(),
      "SUBFLOW_BINARY_STORE_DIR": paths["store"].as_posix(),
      "SUBFLOW_MANAGER_TARGET": paths["manager"].as_posix(),
      "SUBFLOW_SHORTCUT_PATH": paths["shortcut"].as_posix(),
      "SUBFLOW_SYSTEMD_UNIT_PATH": paths["unit"].as_posix(),
      "SUBFLOW_OPENRC_SERVICE_PATH": paths["openrc"].as_posix(),
      "SUBFLOW_RELEASE_MANIFEST_PATH": manifest.as_posix(),
      "SUBFLOW_RELEASE_BASE_URL": "https://example.invalid/releases",
      "SUBFLOW_TEST_ASSET": candidate.as_posix(),
      "SUBFLOW_TEST_CURL_LOG": paths["curl_log"].as_posix(),
      "SUBFLOW_TEST_SERVICE_STATE": paths["service_state"].as_posix(),
      "SUBFLOW_TEST_SERVICE_FAILED": paths["service_failed"].as_posix(),
    })
    if extra:
      env.update(extra)
    return env

  def test_install_uses_approved_digest_and_starts_service(self):
    self._build()
    paths = self._paths()
    candidate = self._candidate()
    manifest = self._manifest(candidate)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, manifest, candidate)

    result = self._run(str(SB_SH), "install", "--version", "9.9.9", env=env)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(paths["binary"].read_bytes(), candidate.read_bytes())
    self.assertEqual(paths["stamp"].read_text(encoding="utf-8").strip(), "9.9.9")
    self.assertEqual((paths["store"] / "9.9.9" / "sing-box").read_bytes(), candidate.read_bytes())
    self.assertIn(paths["binary"].as_posix(), paths["unit"].read_text(encoding="utf-8"))
    self.assertTrue(paths["service_state"].exists())
    self.assertTrue(paths["manager"].exists())
    self.assertTrue(paths["shortcut"].exists())
    self.assertFalse(any(paths["state"].glob(".txn.*")))

  def test_unknown_version_and_bad_digest_never_replace_binary(self):
    self._build()
    paths = self._paths()
    candidate = self._candidate()
    manifest = self._manifest(candidate)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, manifest, candidate)

    unknown = self._run(str(SB_SH), "install", "--version", "8.8.8", env=env)
    self.assertNotEqual(unknown.returncode, 0)
    self.assertIn("版本未获批准", unknown.stderr)
    self.assertFalse(paths["binary"].exists())
    self.assertFalse(paths["curl_log"].exists())

    old_content = b"old-binary\n"
    paths["binary"].parent.mkdir(parents=True)
    paths["binary"].write_bytes(old_content)
    paths["binary"].chmod(0o755)
    bad_manifest = self._manifest(candidate, sha256="0" * 64)
    env["SUBFLOW_RELEASE_MANIFEST_PATH"] = bad_manifest.as_posix()
    mismatch = self._run(str(SB_SH), "install", "--version", "9.9.9", env=env)
    self.assertNotEqual(mismatch.returncode, 0)
    self.assertIn("SHA256 不匹配", mismatch.stderr)
    self.assertEqual(paths["binary"].read_bytes(), old_content)

  def test_candidate_missing_required_build_tag_is_rejected(self):
    self._build()
    paths = self._paths()
    candidate = self._candidate(include_acme=False)
    manifest = self._manifest(candidate)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, manifest, candidate)

    result = self._run(str(SB_SH), "install", "--version", "9.9.9", env=env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("with_acme", result.stderr)
    self.assertFalse(paths["binary"].exists())
    self.assertFalse(any(paths["state"].glob(".txn.*")))

  def test_install_supports_openrc_service(self):
    self._build()
    paths = self._paths()
    candidate = self._candidate()
    manifest = self._manifest(candidate)
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, manifest, candidate, extra={"SUBFLOW_INIT": "openrc"})

    result = self._run(str(SB_SH), "install", env=env)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertTrue(paths["openrc"].exists())
    self.assertIn("command_args=", paths["openrc"].read_text(encoding="utf-8"))
    self.assertTrue(paths["service_state"].exists())

  def test_service_restart_failure_restores_binary_stamp_and_unit(self):
    self._build()
    paths = self._paths()
    candidate = self._candidate()
    manifest = self._manifest(candidate)
    old_binary = self._candidate("1.0.0")
    paths["binary"].parent.mkdir(parents=True)
    shutil.copy2(old_binary, paths["binary"])
    paths["stamp"].write_text("1.0.0\n", encoding="utf-8")
    paths["unit"].parent.mkdir(parents=True)
    paths["unit"].write_text("old service\n", encoding="utf-8")
    paths["service_state"].write_text("active\n", encoding="utf-8")
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, manifest, candidate, extra={"SUBFLOW_TEST_FAIL_RESTART_ONCE": "1"})

    result = self._run(str(SB_SH), "update", env=env)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("已恢复旧版本", result.stderr)
    self.assertEqual(paths["binary"].read_bytes(), old_binary.read_bytes())
    self.assertEqual(paths["stamp"].read_text(encoding="utf-8"), "1.0.0\n")
    self.assertEqual(paths["unit"].read_text(encoding="utf-8"), "old service\n")
    self.assertTrue(paths["service_state"].exists())
    self.assertFalse(any(paths["state"].glob(".txn.*")))

  def test_recover_restores_interrupted_install_transaction(self):
    self._build()
    paths = self._paths()
    candidate = self._candidate()
    manifest = self._manifest(candidate)
    old_binary = self._candidate("1.0.0")
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    self._write_stubs(bin_dir)
    env = self._env(bin_dir, paths, manifest, candidate)

    txn_dir = paths["state"] / ".txn.crash"
    backup_dir = txn_dir / "backup"
    backup_dir.mkdir(parents=True)
    shutil.copy2(old_binary, backup_dir / "sing-box")
    (backup_dir / "installed-release").write_text("1.0.0\n", encoding="utf-8")
    (backup_dir / "service").write_text("old service\n", encoding="utf-8")
    (txn_dir / "recovery.pending").write_text("pending\n", encoding="utf-8")
    (txn_dir / "install.manifest.json").write_text(json.dumps({
      "version": 1,
      "kind": "sing-box-install",
      "txn_dir": txn_dir.as_posix(),
      "state_dir": paths["state"].as_posix(),
      "binary_target": paths["binary"].as_posix(),
      "stamp_target": paths["stamp"].as_posix(),
      "service_target": paths["unit"].as_posix(),
      "init": "systemd",
      "binary_backup": "backup/sing-box",
      "stamp_backup": "backup/installed-release",
      "service_backup": "backup/service",
      "binary_existed": True,
      "stamp_existed": True,
      "service_changed": True,
      "service_existed": True,
      "service_was_active": True,
    }), encoding="utf-8")
    paths["binary"].parent.mkdir(parents=True)
    shutil.copy2(candidate, paths["binary"])
    paths["stamp"].write_text("9.9.9\n", encoding="utf-8")
    paths["unit"].parent.mkdir(parents=True)
    paths["unit"].write_text("new service\n", encoding="utf-8")
    paths["service_state"].write_text("active\n", encoding="utf-8")

    result = self._run(str(SB_SH), "recover", env=env)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(paths["binary"].read_bytes(), old_binary.read_bytes())
    self.assertEqual(paths["stamp"].read_text(encoding="utf-8"), "1.0.0\n")
    self.assertEqual(paths["unit"].read_text(encoding="utf-8"), "old service\n")
    self.assertFalse(txn_dir.exists())


if __name__ == "__main__":
  unittest.main()