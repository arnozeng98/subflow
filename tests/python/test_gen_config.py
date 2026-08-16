import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import gen_config


class SharedConfigGenerationTests(unittest.TestCase):
  def test_subscription_index_path_is_generated_for_both_runtimes(self):
    data = gen_config.parse_yaml(gen_config.YAML_PATH.read_text(encoding="utf-8"))
    paths = data["paths"]
    data_api = data["data_api"]

    bash_output = gen_config.render_bash(paths)
    python_output = gen_config.render_python(paths, data_api)

    expected_path = "/etc/sing-box-manager/subscriptions.json"
    self.assertIn(f'SUBSCRIPTION_INDEX_FILE="{expected_path}"', bash_output)
    self.assertIn(f'SUBSCRIPTION_INDEX_PATH = "{expected_path}"', python_output)


if __name__ == "__main__":
  unittest.main()