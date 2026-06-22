"""
访问上游 sing-box 的运行时配置与元数据。

上游项目把协议定义存放在 `/etc/sing-box/config.json` 中，并把额外的
Reality 元数据存放在 `/etc/sing-box-manager/meta.json` 中。本模块只提供
只读的读取辅助函数；协议检测现在已经改由 Cloudflare 侧负责。
"""

from ..config import AppConfig
from ..utils import load_json_file_cached


def load_config_json(config: AppConfig) -> dict:
  payload = load_json_file_cached(config.config_json_path)
  return payload if isinstance(payload, dict) else {}


def load_meta_json(config: AppConfig) -> dict:
  payload = load_json_file_cached(config.meta_json_path)
  return payload if isinstance(payload, dict) else {}
