"""
Access to the upstream user database.

The upstream project persists user state into `/etc/sing-box-manager/user-manager.json`.
This module translates that JSON into a strict `UsageRecord` model so HTTP
handlers do not depend on raw dictionary lookups.
"""

from ..config import AppConfig
from ..models import UsageRecord
from ..utils import load_json_file_cached


def load_all_users(config: AppConfig) -> dict:
  payload = load_json_file_cached(config.user_db_path)
  return payload.get("users") or {}


def load_usage(config: AppConfig, username: str) -> UsageRecord | None:
  users = load_all_users(config)
  raw = users.get(username)
  if not raw:
    return None

  return UsageRecord(
    username=username,
    enabled=bool(raw.get("enabled", False)),
    disabled_reason=raw.get("disabled_reason"),
    quota_gb=int(raw.get("quota_gb", 0) or 0),
    used_up_bytes=int(raw.get("used_up_bytes", 0) or 0),
    used_down_bytes=int(raw.get("used_down_bytes", 0) or 0),
    manual_added_bytes=int(raw.get("manual_added_bytes", 0) or 0),
    last_reset_period=str(raw.get("last_reset_period", "") or ""),
    reset_day=int(raw.get("reset_day", 0) or 0),
    expire_at=str(raw.get("expire_at", "0") or "0"),
  )
