import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER_PATH = REPO_ROOT / "vps" / "deploy" / "run_subflow.py"
SPEC = importlib.util.spec_from_file_location("run_subflow", LAUNCHER_PATH)
run_subflow = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(run_subflow)


class RunSubflowTests(unittest.TestCase):
  def test_values_are_loaded_as_literal_text(self):
    values = run_subflow.parse_env_file(
      "\n".join((
        "# 注释",
        "SUBFLOW_API_TOKEN=$(touch /tmp/should-not-run)",
        "SUBFLOW_PUBLIC_IP=example.com=value",
      ))
    )

    self.assertEqual(values["SUBFLOW_API_TOKEN"], "$(touch /tmp/should-not-run)")
    self.assertEqual(values["SUBFLOW_PUBLIC_IP"], "example.com=value")

  def test_invalid_keys_and_lines_are_rejected(self):
    for text in ("PATH=/tmp", "SUBFLOW TOKEN=value", "SUBFLOW_TOKEN"):
      with self.subTest(text=text):
        with self.assertRaises(ValueError):
          run_subflow.parse_env_file(text)


if __name__ == "__main__":
  unittest.main()