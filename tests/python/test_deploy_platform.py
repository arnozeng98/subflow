import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEPLOY_ROOT = REPO_ROOT / "vps" / "deploy"


class DeployPlatformTests(unittest.TestCase):
  def test_shared_library_supports_systemd_and_openrc(self):
    shared = (DEPLOY_ROOT / "lib.sh").read_text(encoding="utf-8")

    self.assertIn('SUBFLOW_OPENRC_SERVICE="/etc/init.d/subflow"', shared)
    self.assertIn("detect_init_system()", shared)
    self.assertIn("write_service_unit()", shared)
    self.assertIn('case "${INIT_SYSTEM}" in', shared)
    self.assertIn("systemd)", shared)
    self.assertIn("openrc)", shared)
    self.assertIn("remove_subflow_service()", shared)
    self.assertIn("run_subflow.py", shared)
    self.assertNotIn('env_file="${ENV_FILE}"', shared)

  def test_menu_uses_shared_service_abstraction(self):
    menu = (DEPLOY_ROOT / "menu.sh").read_text(encoding="utf-8")

    self.assertNotIn("systemctl", menu)
    self.assertNotIn("journalctl", menu)
    self.assertIn("service_start", menu)
    self.assertIn("service_logs", menu)
    self.assertIn("service_status", menu)

  def test_install_and_uninstall_use_shared_service_lifecycle(self):
    install = (DEPLOY_ROOT / "install.sh").read_text(encoding="utf-8")
    uninstall = (DEPLOY_ROOT / "uninstall.sh").read_text(encoding="utf-8")

    self.assertIn("write_service_unit", install)
    self.assertNotIn("write_systemd_unit", install)
    self.assertIn("remove_subflow_service", uninstall)


if __name__ == "__main__":
  unittest.main()