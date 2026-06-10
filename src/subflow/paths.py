"""
Central place for upstream path defaults.

These values are derived from Tangfffyx/sing-box rather than guessed locally.
The goal is to keep every path decision in one module so future upstream changes
do not require a repo-wide grep and risky manual edits.
"""

from pathlib import Path


# Upstream main sing-box runtime configuration.
DEFAULT_CONFIG_JSON_PATH = Path("/etc/sing-box/config.json")

# Upstream multi-user manager database. This is where accumulated quota and
# usage counters are persisted by the upstream manager.
DEFAULT_USER_DB_PATH = Path("/etc/sing-box-manager/user-manager.json")

# Upstream metadata store. Reality public keys and related per-inbound metadata
# are stored here by the upstream scripts.
DEFAULT_META_JSON_PATH = Path("/etc/sing-box-manager/meta.json")

# Upstream Telegram integration state. We do not require it for first-party
# subscription generation, but keeping the path here documents the ecosystem.
DEFAULT_TELEGRAM_JSON_PATH = Path("/etc/sing-box-manager/telegram.json")

# Local subflow deployment defaults.
DEFAULT_ENV_FILE_PATH = Path("/etc/subflow/subflow.env")
DEFAULT_INSTALL_ROOT = Path("/opt/subflow")
