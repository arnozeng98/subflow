"""
访问上游的用户数据库。

上游项目将用户状态持久化到 `/etc/sing-box-manager/user-manager.json`。
本模块把该 JSON 转换为严格的 `UsageRecord` 模型，使 HTTP 处理逻辑无需
直接依赖原始字典的字段查找，从而隔离上游数据结构的变化。
"""

from typing import Optional

from ..config import AppConfig
from ..models import UsageRecord
from ..utils import load_json_file_cached


def load_all_users(config: AppConfig) -> dict:
  payload = load_json_file_cached(config.user_db_path)
  return payload.get("users") or {}


def usage_record_from_raw(username: str, raw) -> Optional[UsageRecord]:
  if not isinstance(raw, dict):
    return None

  try:
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
  except (TypeError, ValueError):
    return None


def load_usage(config: AppConfig, username: str) -> Optional[UsageRecord]:
  users = load_all_users(config)
  return usage_record_from_raw(username, users.get(username))
