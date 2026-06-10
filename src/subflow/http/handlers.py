"""
HTTP handlers for the private data API.

The handler is intentionally thin and does no rendering:

1. Authenticate request.
2. Parse the username route input.
3. Return a raw, user-scoped projection of upstream state as JSON.

All client format negotiation and configuration assembly live on the Cloudflare
side. This service only exposes data.
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
  """HTTP handler factory target used by ThreadingHTTPServer."""

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
