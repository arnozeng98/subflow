"""
Raw upstream projection.

The VPS service is a pure data API: it never renders client formats. This module
filters the upstream sing-box state down to a single business user and returns
the matching inbounds *as raw slices*, plus the Reality metadata those inbounds
need. All protocol detection, link building, and template assembly happen on the
Cloudflare side. Keeping this layer free of rendering logic is what lets the
public gateway own configuration generation.

Security note: every inbound slice contains only the requesting user's own
credential entry. We never expose other tenants' UUIDs or passwords, even though
the upstream config.json stores them all together.
"""

from copy import deepcopy

from ..config import AppConfig
from ..data_sources.config_json import load_config_json, load_meta_json
from ..utils import business_username


def _inbound_users(inbound: dict) -> list:
  users = inbound.get("users") or []
  return users if isinstance(users, list) else []


def _user_name_field(user: dict) -> str:
  return str(user.get("name") or user.get("username") or "")


def build_raw_payload(config: AppConfig, username: str) -> dict:
  """
  Project upstream state into a raw, user-scoped payload for the JS layer.

  Returns inbound slices that contain only the requested user's credential entry,
  along with the Reality public-key metadata keyed by inbound tag. Returns an
  empty payload (no inbounds) when the user owns no nodes.
  """

  config_json = load_config_json(config)
  meta_json = load_meta_json(config)

  inbounds: list[dict] = []
  meta: dict[str, dict] = {}

  for inbound in config_json.get("inbounds") or []:
    inbound_tag = str(inbound.get("tag") or "")
    if not inbound_tag:
      continue

    matching_users = [
      user
      for user in _inbound_users(inbound)
      if _user_name_field(user) and business_username(_user_name_field(user)) == username
    ]
    if not matching_users:
      continue

    slice_inbound = deepcopy(inbound)
    slice_inbound["users"] = deepcopy(matching_users)
    inbounds.append(slice_inbound)

    tag_meta = meta_json.get(inbound_tag)
    if isinstance(tag_meta, dict) and tag_meta.get("public_key"):
      meta[inbound_tag] = {"public_key": str(tag_meta.get("public_key"))}

  return {
    "inbounds": inbounds,
    "meta": meta,
    "public_ip": config.public_ip,
    "ws_domains": {
      "vless": config.vless_ws_domain,
      "vmess": config.vmess_ws_domain,
    },
  }
