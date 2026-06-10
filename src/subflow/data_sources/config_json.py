"""
Access to upstream sing-box runtime configuration and metadata.

The upstream project stores protocol definitions in `/etc/sing-box/config.json`
and auxiliary Reality metadata in `/etc/sing-box-manager/meta.json`. This module
exposes read helpers only; protocol detection now happens on the Cloudflare side.
"""

from ..config import AppConfig
from ..utils import load_json_file_cached


def load_config_json(config: AppConfig) -> dict:
  payload = load_json_file_cached(config.config_json_path)
  return payload if isinstance(payload, dict) else {}


def load_meta_json(config: AppConfig) -> dict:
  payload = load_json_file_cached(config.meta_json_path)
  return payload if isinstance(payload, dict) else {}
