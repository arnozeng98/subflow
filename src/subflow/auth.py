"""
Authorization helpers.

The private API is intentionally minimal and not exposed directly to the public
internet in the intended deployment. Even so, every route is protected with a
Bearer token because Cloudflare Pages needs a simple machine-to-machine auth
mechanism that can live in secrets storage.
"""

from .config import AppConfig


def is_authorized(headers, config: AppConfig) -> bool:
  """Return True when the request carries the exact expected Bearer token."""

  if not config.api_token:
    return False
  return headers.get("Authorization", "") == f"Bearer {config.api_token}"
