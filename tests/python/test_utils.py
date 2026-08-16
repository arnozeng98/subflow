import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "vps"))

from subflow.utils import load_json_file_cached


class JsonFileCacheTests(unittest.TestCase):
  def test_atomic_replacement_invalidates_cache_even_with_same_mtime(self):
    with tempfile.TemporaryDirectory() as temp_dir:
      path = Path(temp_dir) / "state.json"
      replacement = Path(temp_dir) / "state.next.json"
      path.write_text(json.dumps({"value": "first"}), encoding="utf-8")
      initial_stat = path.stat()

      self.assertEqual(load_json_file_cached(path), {"value": "first"})

      replacement.write_text(json.dumps({"value": "other"}), encoding="utf-8")
      os.utime(
        replacement,
        ns=(initial_stat.st_atime_ns, initial_stat.st_mtime_ns),
      )
      os.replace(replacement, path)

      self.assertEqual(path.stat().st_mtime_ns, initial_stat.st_mtime_ns)
      self.assertEqual(load_json_file_cached(path), {"value": "other"})

  def test_invalid_utf8_is_treated_as_invalid_json(self):
    with tempfile.TemporaryDirectory() as temp_dir:
      path = Path(temp_dir) / "state.json"
      path.write_bytes(b"\xff\xfe\x00")

      self.assertEqual(load_json_file_cached(path), {})

  def test_stat_failure_returns_empty_payload(self):
    path = Path("unreadable.json")

    with patch.object(Path, "stat", side_effect=PermissionError("denied")):
      self.assertEqual(load_json_file_cached(path), {})


if __name__ == "__main__":
  unittest.main()