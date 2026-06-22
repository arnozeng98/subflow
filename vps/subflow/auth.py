"""
鉴权辅助函数。

这套私有 API 刻意保持精简，在预期的部署形态中并不直接暴露到公网。即便如此，
每个路由仍以 Bearer Token 加以保护——因为 Cloudflare Pages 需要一套简单的
机器对机器（machine-to-machine）鉴权机制，且该机制可以存放在密钥存储中。
"""

from .config import AppConfig


def is_authorized(headers, config: AppConfig) -> bool:
  """当请求携带与预期完全一致的 Bearer Token 时返回 True。

  注意：若未配置 api_token（为空字符串），则一律返回 False，以避免在缺失
  令牌的情况下意外放行所有请求。比较采用精确字符串匹配，不接受任何前后缀差异。"""

  if not config.api_token:
    return False
  return headers.get("Authorization", "") == f"Bearer {config.api_token}"
