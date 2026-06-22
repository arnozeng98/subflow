"""
上游状态的原始投影。

VPS 服务是一个纯数据 API：它从不渲染客户端格式。本模块把上游 sing-box
状态过滤到单个业务用户，并以*原始切片*的形式返回匹配的 inbound，
连同这些 inbound 所需的 Reality 元数据。所有协议检测、链接构建与模板组装
都发生在 Cloudflare 侧。正是因为本层不含渲染逻辑，公共网关才能独立
掌控配置生成。

安全提示：每个 inbound 切片仅包含发起请求的用户自己的凭证条目。
即使上游 config.json 把所有用户的凭证存放在一起，我们也绝不会暴露其他
租户的 UUID 或密码。
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
  把上游状态投影为供 JS 层使用的、按用户切分的原始负载。

  返回的 inbound 切片仅包含所请求用户的凭证条目，并附带以 inbound tag
  为键的 Reality 公钥元数据。当该用户不拥有任何节点时，返回空负载
  （不含 inbounds）。
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
