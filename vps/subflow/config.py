"""
运行时配置加载。

VPS 服务是纯数据 API。它从环境变量读取每项设置，以保持安装程序简洁，
并实现清晰的 systemd 集成。此处绝不会硬编码任何业务值（服务器地址、域名、令牌）；
以下字段是运行时行为的唯一事实来源。
"""

from dataclasses import dataclass
import os
from pathlib import Path

from . import paths
from . import _defaults


@dataclass(frozen=True)
class AppConfig:
  """subflow 私有数据 API 的不可变运行时配置。"""

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
  subscription_index_path: Path = paths.DEFAULT_SUBSCRIPTION_INDEX_PATH


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
  从环境变量构建应用程序配置。

  路径默认值与捆绑的 sing-box 管理器布局一致，使全新的 subflow 实例无需重新查找
  文件位置即可连接到本地 sing-box 数据。所有面向运维人员的值（公网 IP、WebSocket
  域名、令牌）都必须通过环境变量提供，绝不会由代码自行假定。
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
    subscription_index_path=_read_path(
      "SUBFLOW_SUBSCRIPTION_INDEX_PATH",
      paths.DEFAULT_SUBSCRIPTION_INDEX_PATH,
    ),
  )
