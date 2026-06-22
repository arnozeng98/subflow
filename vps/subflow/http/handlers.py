"""
私有数据 API 的 HTTP 处理器。

该处理器有意保持轻量，不做任何渲染：

1. 对请求进行鉴权。
2. 解析路由中的用户名输入。
3. 以 JSON 返回上游状态中按用户切分的原始投影。

所有客户端格式协商与配置组装都位于 Cloudflare 侧。本服务仅暴露
原始数据。
"""

import json
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlsplit, unquote

from ..auth import is_authorized
from ..config import AppConfig
from ..data_sources.user_db import load_usage
from ..services.raw_projection import build_raw_payload
from ..utils import normalize_username


def _json_bytes(payload) -> bytes:
  return json.dumps(payload, ensure_ascii=False).encode("utf-8")


class RequestHandler(BaseHTTPRequestHandler):
  """供 ThreadingHTTPServer 使用的 HTTP 处理器工厂目标类。"""

  config: AppConfig = None

  def log_message(self, fmt, *args):
    return

  def do_GET(self):
    if not is_authorized(self.headers, self.config):
      self.write_bytes(403, b"forbidden", "text/plain; charset=utf-8")
      return

    request_url = urlsplit(self.path)
    path = request_url.path or "/"

    if path == "/healthz":
      self.write_bytes(200, b"ok", "text/plain; charset=utf-8")
      return

    if path.startswith("/internal/raw/"):
      self.handle_raw(path)
      return

    self.write_bytes(404, b"not found", "text/plain; charset=utf-8")

  def handle_raw(self, path: str):
    username = normalize_username(unquote(path[len("/internal/raw/"):]))
    if not username:
      self.write_bytes(404, b"not found", "text/plain; charset=utf-8")
      return

    usage = load_usage(self.config, username)
    if not usage:
      self.write_bytes(404, b"not found", "text/plain; charset=utf-8")
      return
    if not self.config.include_disabled_users and not usage.enabled:
      self.write_bytes(404, b"not found", "text/plain; charset=utf-8")
      return

    payload = build_raw_payload(self.config, username)
    if not payload.get("inbounds"):
      self.write_bytes(404, b"not found", "text/plain; charset=utf-8")
      return

    payload["username"] = username
    payload["enabled"] = usage.enabled
    payload["usage"] = usage.__dict__
    self.write_bytes(200, _json_bytes(payload), "application/json; charset=utf-8")

  def write_bytes(self, status_code: int, payload: bytes, content_type: str):
    self.send_response(status_code)
    self.send_header("Content-Type", content_type)
    self.send_header("Content-Length", str(len(payload)))
    self.send_header("Cache-Control", "no-store")
    self.end_headers()
    self.wfile.write(payload)
