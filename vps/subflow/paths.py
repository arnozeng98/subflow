"""
sing-box 路径默认值的集中定义处。

这些取值统一来自 configs/defaults.yaml（经 scripts/gen_config.py 生成的 _defaults），
而非在各处零散猜测。把路径决策收拢到一个模块，日后 sing-box 布局变化时无需全仓库
grep、也避免高风险的手工逐处修改。
"""

from pathlib import Path

from . import _defaults


# sing-box 主配置（由内置管理器写入、数据 API 读取）。
DEFAULT_CONFIG_JSON_PATH = Path(_defaults.SINGBOX_CONFIG_PATH)

# 多用户管理库：累计配额与用量计数由管理器持久化在此。
DEFAULT_USER_DB_PATH = Path(_defaults.USER_DB_PATH)

# 元数据存储：reality 公钥及每个 inbound 的相关元数据写在此处。
DEFAULT_META_JSON_PATH = Path(_defaults.META_PATH)

# Telegram 集成状态：首方订阅生成并不需要它，保留路径以记录整个生态。
DEFAULT_TELEGRAM_JSON_PATH = Path(_defaults.TELEGRAM_PATH)

# 本地 subflow 部署默认值。
DEFAULT_ENV_FILE_PATH = Path("/etc/subflow/subflow.env")
DEFAULT_INSTALL_ROOT = Path("/opt/subflow")
