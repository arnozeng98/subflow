"""
Main entrypoint for the VPS-side private API.

This module wires the configuration object into the HTTP server and nothing more.
That narrow scope is intentional: installers, service registration, handlers,
format logic, and data loading all live elsewhere so they can evolve and be
tested independently.
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