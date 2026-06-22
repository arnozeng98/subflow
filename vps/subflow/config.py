"""
Runtime configuration loading.

The VPS service is a pure data API. It reads every setting from environment
variables so the installer stays simple and systemd integration is clean. No
business value (server address, domains, tokens) is ever hard-coded here; the
fields below are the single source of truth for runtime behavior.
"""

from dataclasses import dataclass
import os
from pathlib import Path

from . import paths
from . import _defaults


@dataclass(frozen=True)
class AppConfig:
  """Immutable runtime configuration for the subflow private data API."""

  listen_host: str
  listen_port: int
  api_token: str
  config_json_path: Path
  user_db_path: Path
  meta_json_path: Path
  public_ip: str
  vless_ws_domain: str
  vmess_ws_domain: str
  include_disabled_users: bool


def _read_bool(name: str, default: bool) -> bool:
  raw = os.environ.get(name)
  if raw is None:
    return default
  return raw.strip().lower() in {"1", "true", "yes", "on"}


def _read_int(name: str, default: int) -> int:
  raw = os.environ.get(name)
  if raw is None or not raw.strip():
    return default
  return int(raw)


def _read_path(name: str, default: Path) -> Path:
  raw = os.environ.get(name)
  if raw is None or not raw.strip():
    return default
  return Path(raw.strip())


def load_config() -> AppConfig:
  """
  Build application configuration from environment variables.

  Path defaults mirror the bundled sing-box manager's layout so a fresh subflow
  instance attaches to the local sing-box data without re-discovering file locations.
  Every operator-facing value (public IP, WebSocket domains, token) must be
  supplied via environment variables and is never assumed from code.
  """

  return AppConfig(
    listen_host=os.environ.get("SUBFLOW_LISTEN_HOST", _defaults.DATA_API_LISTEN_HOST).strip() or _defaults.DATA_API_LISTEN_HOST,
    listen_port=_read_int("SUBFLOW_LISTEN_PORT", _defaults.DATA_API_LISTEN_PORT),
    api_token=os.environ.get("SUBFLOW_API_TOKEN", "").strip(),
    config_json_path=_read_path("SUBFLOW_CONFIG_PATH", paths.DEFAULT_CONFIG_JSON_PATH),
    user_db_path=_read_path("SUBFLOW_USER_DB_PATH", paths.DEFAULT_USER_DB_PATH),
    meta_json_path=_read_path("SUBFLOW_META_PATH", paths.DEFAULT_META_JSON_PATH),
    public_ip=os.environ.get("SUBFLOW_PUBLIC_IP", "").strip(),
    vless_ws_domain=os.environ.get("SUBFLOW_WS_DOMAIN", "").strip(),
    vmess_ws_domain=os.environ.get("SUBFLOW_VMESS_WS_DOMAIN", "").strip(),
    include_disabled_users=_read_bool("SUBFLOW_INCLUDE_DISABLED_USERS", False),
  )
