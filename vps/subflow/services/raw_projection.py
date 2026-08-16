"""
上游状态的安全投影。

VPS 服务是一个纯数据 API：它从不渲染客户端格式。本模块把上游 sing-box
状态过滤到单个业务用户，再按照客户端数据契约逐字段构造 inbound 投影，
连同这些 inbound 所需的 Reality 公钥元数据返回。所有协议检测、链接构建与
模板组装都发生在 Cloudflare 侧。

安全边界：投影只能包含客户端建立连接所需的字段。Reality 私钥、TLS 私钥、
证书路径、ACME Token、内部监听地址及其他租户凭据都不得离开 VPS。
"""

from copy import deepcopy

from ..config import AppConfig
from ..data_sources.config_json import load_config_json, load_meta_json
from ..utils import business_username


RAW_PAYLOAD_SCHEMA_VERSION = 1


def _inbound_users(inbound: dict) -> list:
  users = inbound.get("users") or []
  return users if isinstance(users, list) else []


def _user_name_field(user: dict) -> str:
  return str(user.get("name") or user.get("username") or "")


def _project_user(user: dict) -> dict:
  projected: dict = {}
  for field in ("name", "username", "uuid", "password", "flow"):
    if field in user:
      projected[field] = deepcopy(user[field])
  return projected


def _project_inbound(inbound: dict, matching_users: list[dict]) -> dict:
  projected: dict = {}
  for field in ("type", "tag", "listen_port"):
    if field in inbound:
      projected[field] = deepcopy(inbound[field])

  if inbound.get("type") == "shadowsocks":
    for field in ("method", "password"):
      if field in inbound:
        projected[field] = deepcopy(inbound[field])

  projected["users"] = [_project_user(user) for user in matching_users]

  transport = inbound.get("transport")
  if isinstance(transport, dict):
    projected_transport = {
      field: deepcopy(transport[field])
      for field in ("type", "path")
      if field in transport
    }
    if projected_transport:
      projected["transport"] = projected_transport

  tls = inbound.get("tls")
  if isinstance(tls, dict):
    projected_tls = {}
    if "server_name" in tls:
      projected_tls["server_name"] = deepcopy(tls["server_name"])

    reality = tls.get("reality")
    if isinstance(reality, dict):
      projected_reality = {
        field: deepcopy(reality[field])
        for field in ("enabled", "short_id")
        if field in reality
      }
      if projected_reality:
        projected_tls["reality"] = projected_reality

    if projected_tls:
      projected["tls"] = projected_tls

  return projected


def _build_payload(config: AppConfig, username: str, source_inbounds, meta_json) -> dict:
  inbounds: list[dict] = []
  meta: dict[str, dict] = {}

  for inbound in source_inbounds:
    if not isinstance(inbound, dict):
      continue
    inbound_tag = str(inbound.get("tag") or "")
    if not inbound_tag:
      continue

    matching_users = [
      user
      for user in _inbound_users(inbound)
      if isinstance(user, dict)
      and _user_name_field(user)
      and business_username(_user_name_field(user)) == username
    ]
    if not matching_users:
      continue

    inbounds.append(_project_inbound(inbound, matching_users))

    tag_meta = meta_json.get(inbound_tag)
    if isinstance(tag_meta, dict) and tag_meta.get("public_key"):
      meta[inbound_tag] = {"public_key": str(tag_meta.get("public_key"))}

  return {
    "schema_version": RAW_PAYLOAD_SCHEMA_VERSION,
    "inbounds": inbounds,
    "meta": meta,
    "public_ip": config.public_ip,
    "ws_domains": {
      "vless": config.vless_ws_domain,
      "vmess": config.vmess_ws_domain,
    },
  }


def build_raw_payload(config: AppConfig, username: str) -> dict:
  """从旧版 sing-box 文件构建安全负载，供迁移期兼容使用。"""

  config_json = load_config_json(config)
  meta_json = load_meta_json(config)
  source_inbounds = config_json.get("inbounds") or []
  if not isinstance(source_inbounds, list):
    source_inbounds = []
  if not isinstance(meta_json, dict):
    meta_json = {}
  return _build_payload(config, username, source_inbounds, meta_json)


def build_indexed_payload(config: AppConfig, username: str, record: dict) -> dict:
  """从版本化索引记录再次执行白名单投影，绝不直接回传索引内容。"""

  return _build_payload(
    config,
    username,
    record.get("inbounds") or [],
    record.get("meta") or {},
  )
