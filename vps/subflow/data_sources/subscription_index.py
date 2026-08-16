"""读取由管理器生成的版本化订阅索引。"""

from copy import deepcopy
from dataclasses import dataclass
from enum import Enum
import stat
from typing import Optional

from ..config import AppConfig
from ..utils import load_json_file_cached


SUBSCRIPTION_INDEX_SCHEMA_VERSION = 1


class SubscriptionIndexStatus(str, Enum):
  """索引查询结果；调用方必须显式处理每一种状态。"""

  MISSING = "missing"
  INVALID = "invalid"
  NOT_FOUND = "not_found"
  FOUND = "found"


@dataclass(frozen=True)
class SubscriptionIndexLookup:
  status: SubscriptionIndexStatus
  record: Optional[dict] = None


def lookup_subscription(config: AppConfig, username: str) -> SubscriptionIndexLookup:
  """查询单个用户；只有索引文件缺失时才允许调用方走兼容路径。"""

  index_path = config.subscription_index_path
  try:
    stat_result = index_path.stat()
  except FileNotFoundError:
    return SubscriptionIndexLookup(SubscriptionIndexStatus.MISSING)
  except OSError:
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if not stat.S_ISREG(stat_result.st_mode):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)

  payload = load_json_file_cached(index_path)
  if not isinstance(payload, dict):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if type(payload.get("schema_version")) is not int:
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if payload.get("schema_version") != SUBSCRIPTION_INDEX_SCHEMA_VERSION:
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)

  users = payload.get("users")
  if not isinstance(users, dict):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if username not in users:
    return SubscriptionIndexLookup(SubscriptionIndexStatus.NOT_FOUND)

  record = users.get(username)
  if not isinstance(record, dict):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if not isinstance(record.get("usage"), dict):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if not isinstance(record.get("inbounds"), list):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  if not isinstance(record.get("meta"), dict):
    return SubscriptionIndexLookup(SubscriptionIndexStatus.INVALID)
  return SubscriptionIndexLookup(SubscriptionIndexStatus.FOUND, deepcopy(record))