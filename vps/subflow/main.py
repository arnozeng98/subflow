"""
VPS 侧私有 API 的主入口。

本模块仅负责把配置对象接入 HTTP 服务器，除此之外别无他事。这种极窄的职责
范围是刻意为之：安装器、服务注册、请求处理器、格式化逻辑以及数据加载都各自
位于其他模块，从而可以独立演进、独立测试。
"""

from http.server import ThreadingHTTPServer

from .config import load_config
from .http.handlers import RequestHandler


def build_server() -> ThreadingHTTPServer:
  config = load_config()
  RequestHandler.config = config
  return ThreadingHTTPServer((config.listen_host, config.listen_port), RequestHandler)


def main():
  server = build_server()
  server.serve_forever()