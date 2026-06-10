"""
Low-level shared helpers.

Utility functions live here only when they are generic enough to be reused by
multiple modules. The VPS service is a pure data API, so these helpers cover
username validation, JSON loading with an mtime cache, and the upstream user
naming convention.
"""

import json
from pathlib import Path
from typing import Any


USERNAME_ALLOWED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")


def normalize_username(raw_value: str) -> str:
  """Normalize and validate usernames according to the public route contract."""

  value = (raw_value or "").strip()
  if not value or len(value) > 64:
    return ""
  if any(character not in USERNAME_ALLOWED for character in value):
    return ""
  return value


def load_json_file(file_path: Path) -> Any:
  """Read a JSON file and return a safe fallback object when it is missing."""

  try:
    with file_path.open("r", encoding="utf-8") as handle:
      return json.load(handle)
  except FileNotFoundError:
    return {}
  except json.JSONDecodeError:
    return {}


# In-process cache for upstream JSON files keyed by absolute path. Each entry
# stores the modification time it was read at, so a stale file is re-parsed only
# when the upstream manager actually rewrites it. This avoids re-reading and
# re-parsing potentially large config.json files on every subscription request.
_JSON_CACHE: dict[str, tuple[float, Any]] = {}


def load_json_file_cached(file_path: Path) -> Any:
  """Load a JSON file, reusing a cached parse while the file mtime is unchanged."""

  key = str(file_path)
  try:
    mtime = file_path.stat().st_mtime
  except FileNotFoundError:
    _JSON_CACHE.pop(key, None)
    return {}

  cached = _JSON_CACHE.get(key)
  if cached is not None and cached[0] == mtime:
    return cached[1]

  payload = load_json_file(file_path)
  _JSON_CACHE[key] = (mtime, payload)
  return payload



def business_username(full_name: str) -> str:
  """
  Match the upstream naming convention used by Tangfffyx/sing-box.

  Upstream code stores business users as `<node>@<username>` for non-admin users.
  Entries without `@` belong to the built-in admin user.
  """

  if "@" in full_name:
    return full_name.split("@", 1)[1]
  return "admin"
