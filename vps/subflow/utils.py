"""
底层通用辅助函数。

只有足够通用、可被多个模块复用的工具函数才放在这里。VPS 服务是一个纯数据 API，
因此这些辅助函数主要涵盖：用户名校验、带 mtime 缓存的 JSON 加载，以及上游的
用户命名约定。
"""

import json
from pathlib import Path
from typing import Any


USERNAME_ALLOWED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")


def normalize_username(raw_value: str) -> str:
  """按公开路由约定对用户名进行规范化与校验。

  去除首尾空白后，用户名必须非空、长度不超过 64，且仅允许字母、数字、下划线
  与连字符。任何不合法输入都返回空字符串，用作“拒绝”信号，以防止路径穿越等
  注入类问题。"""

  value = (raw_value or "").strip()
  if not value or len(value) > 64:
    return ""
  if any(character not in USERNAME_ALLOWED for character in value):
    return ""
  return value


def load_json_file(file_path: Path) -> Any:
  """读取一个 JSON 文件；当文件缺失或内容无法解析时，返回安全的退路对象（空 dict）。

  这样调用方无需区分“文件不存在”与“内容损坏”两种异常，可以始终拿到一个可遍历的对象。"""

  try:
    with file_path.open("r", encoding="utf-8") as handle:
      return json.load(handle)
  except FileNotFoundError:
    return {}
  except json.JSONDecodeError:
    return {}


# 进程内的上游 JSON 文件缓存，以绝对路径为键。每个条目记录读取时的修改时间
# （mtime），因此只有当上游管理器真正重写了文件时，陈旧的文件才会被重新解析。
# 这避免了在每次订阅请求时都去重复读取、重复解析可能体量较大的 config.json 文件。
_JSON_CACHE: dict[str, tuple[float, Any]] = {}


def load_json_file_cached(file_path: Path) -> Any:
  """加载 JSON 文件；在文件 mtime 未变期间复用上一次的解析结果。

  若文件已被删除（抛出 FileNotFoundError），则清除其缓存条目并返回空 dict；若 mtime
  发生变化，则重新读取并更新缓存。"""

  key = str(file_path)
  try:
    mtime = file_path.stat().st_mtime
  except FileNotFoundError:
    _JSON_CACHE.pop(key, None)
    return {}

  cached = _JSON_CACHE.get(key)
  if cached is not None and cached[0] == mtime:
    return cached[1]

  payload = load_json_file(file_path)
  _JSON_CACHE[key] = (mtime, payload)
  return payload



def business_username(full_name: str) -> str:
  """
  与内置 sing-box 管理器使用的命名约定保持一致。

  对于非管理员用户，管理器将业务用户存为 `<node>@<username>` 的形式。
  不含 `@` 的条目则归属于内置的 admin 用户。
  """

  if "@" in full_name:
    return full_name.split("@", 1)[1]
  return "admin"
