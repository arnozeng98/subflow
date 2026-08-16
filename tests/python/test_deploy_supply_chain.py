import json
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CF_DEPLOY = REPO_ROOT / "vps" / "deploy" / "cf-deploy.sh"
DEPLOY_LIB = REPO_ROOT / "vps" / "deploy" / "lib.sh"
UNINSTALL = REPO_ROOT / "vps" / "deploy" / "uninstall.sh"
DEPENDENCY_LOCK = REPO_ROOT / "configs" / "dependencies.lock.json"
DEPENDENCY_SHELL = REPO_ROOT / "vps" / "deploy" / "dependencies.sh"


class DeploySupplyChainTests(unittest.TestCase):
  def test_node_is_not_installed_by_remote_shell_pipeline(self):
    script = CF_DEPLOY.read_text(encoding="utf-8")

    self.assertNotIn("deb.nodesource.com", script)
    self.assertIsNone(re.search(r"curl[^\n|]*\|[^\n]*(?:bash|sh)", script))

  def test_wrangler_version_and_integrity_are_pinned(self):
    script = CF_DEPLOY.read_text(encoding="utf-8")
    generated = DEPENDENCY_SHELL.read_text(encoding="utf-8")
    dependency_lock = json.loads(DEPENDENCY_LOCK.read_text(encoding="utf-8"))

    self.assertIn('source "${SCRIPT_DIR}/dependencies.sh"', script)
    self.assertEqual(dependency_lock["wrangler"]["version"], "4.48.0")
    self.assertEqual(dependency_lock["wrangler"]["node_min_major"], 18)
    self.assertIn('WRANGLER_VERSION="4.48.0"', generated)
    self.assertIn('WRANGLER_NODE_MIN_MAJOR="18"', generated)
    self.assertIn(
      'WRANGLER_INTEGRITY="sha512-qkcwysx96XNDWXl4w/5VjAZjqWatxAq9chMXVeqv/etL9e06ouPaZ+Hwwbe5XYV2GYf/XhZVZ3fHJcTBrq60gQ=="',
      generated,
    )
    self.assertIn('npx --yes "wrangler@${WRANGLER_VERSION}" pages deploy', script)

  def test_cloudflared_version_and_architecture_hashes_are_pinned(self):
    script = CF_DEPLOY.read_text(encoding="utf-8")
    generated = DEPENDENCY_SHELL.read_text(encoding="utf-8")
    dependency_lock = json.loads(DEPENDENCY_LOCK.read_text(encoding="utf-8"))

    self.assertNotIn("releases/latest/download", script)
    self.assertEqual(dependency_lock["cloudflared"]["version"], "2026.8.2")
    self.assertIn('CLOUDFLARED_VERSION="2026.8.2"', generated)
    self.assertIn(
      '[amd64]="fcfb02b575a52ca1af2e3267af4e1517bcdeb30ac48c834c69abaed3c0576ad2"',
      generated,
    )
    self.assertIn(
      '[arm64]="7747d94570fb390cf47dcb4f9555c193c6355cda9793f0d878d9049e5d6a7790"',
      generated,
    )
    self.assertIn(
      '[arm]="19809425f60a6261241dfa66a42b4115bab07c295396a3c4d5d7c247fc4e1412"',
      generated,
    )
    self.assertIn("sha256sum", script)

  def test_tunnel_uses_project_service_and_token_file(self):
    script = CF_DEPLOY.read_text(encoding="utf-8")
    shared = DEPLOY_LIB.read_text(encoding="utf-8") + script

    self.assertNotIn("cloudflared service uninstall", script)
    self.assertNotIn('cloudflared service install "${token}"', script)
    self.assertIn('SUBFLOW_CLOUDFLARED_SERVICE="subflow-cloudflared"', shared)
    self.assertIn('SUBFLOW_CLOUDFLARED_TOKEN_FILE="${ENV_DIR}/cloudflared.token"', shared)
    self.assertIn('chmod 600 "${SUBFLOW_CLOUDFLARED_TOKEN_FILE}"', script)
    self.assertIn('tunnel run --token-file ${SUBFLOW_CLOUDFLARED_TOKEN_FILE}', script)
    self.assertIn('case "${init_system}" in', script)
    self.assertIn('systemd)', script)
    self.assertIn('openrc)', script)

  def test_uninstall_only_removes_project_tunnel_service(self):
    script = UNINSTALL.read_text(encoding="utf-8")

    self.assertIn('systemctl stop "${SUBFLOW_CLOUDFLARED_SERVICE}"', script)
    self.assertIn('rc-service "${SUBFLOW_CLOUDFLARED_SERVICE}" stop', script)
    self.assertIn('rm -f "${SUBFLOW_CLOUDFLARED_TOKEN_FILE}"', script)
    self.assertNotIn("cloudflared service uninstall", script)
    self.assertNotRegex(script, r"systemctl\s+(?:stop|disable)\s+cloudflared(?:\s|$)")

  def test_generated_bearer_is_persisted_to_vps_before_deploy(self):
    script = CF_DEPLOY.read_text(encoding="utf-8")

    self.assertIn('CFG_VALUE[SUBFLOW_API_TOKEN]="${CF_BEARER}"', script)
    self.assertIn("save_env", script)
    self.assertIn("reload_and_restart", script)
    self.assertNotIn("请确保 VPS 端也使用它", script)

  def test_dns_records_are_not_silently_taken_over(self):
    script = CF_DEPLOY.read_text(encoding="utf-8")

    self.assertIn("ensure_managed_cname()", script)
    self.assertIn('[[ "${existing_type}" != "CNAME" ]]', script)
    self.assertIn('[[ "${existing_target}" != "${normalized_target}" ]]', script)
    self.assertIn("拒绝覆盖", script)


if __name__ == "__main__":
  unittest.main()