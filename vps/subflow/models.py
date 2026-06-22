"""
共享数据模型。

本服务使用显式定义的 dataclass，而非在模块之间传递结构松散的 dict。
`UsageRecord` 是对单个用户配额与状态的归一化视图，其数据由上游管理器持久化。
"""

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class UsageRecord:
  username: str
  enabled: bool
  disabled_reason: Optional[str]
  quota_gb: int
  used_up_bytes: int
  used_down_bytes: int
  manual_added_bytes: int
  last_reset_period: str
  reset_day: int
  expire_at: str
