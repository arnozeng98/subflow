"""
Shared data models.

The service uses explicit dataclasses instead of passing loosely-shaped dicts
between modules. `UsageRecord` is the normalized view of a single user's quota
and status as persisted by the upstream manager.
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
