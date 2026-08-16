#!/usr/bin/env python3
"""为 OpenRC 加载 subflow 环境文件并启动数据 API。"""

import os
from pathlib import Path
import re
from typing import Dict


DEFAULT_ENV_FILE = Path("/etc/subflow/subflow.env")
ENV_KEY_PATTERN = re.compile(r"^SUBFLOW_[A-Z0-9_]+$")


def parse_env_file(text: str) -> Dict[str, str]:
  """解析简单的 KEY=VALUE 文件；值始终作为纯文本，不执行 shell 展开。"""

  values: Dict[str, str] = {}
  for line_number, raw_line in enumerate(text.splitlines(), start=1):
    line = raw_line.strip()
    if not line or line.startswith("#"):
      continue
    key, separator, value = line.partition("=")
    key = key.strip()
    if not separator or not ENV_KEY_PATTERN.fullmatch(key):
      raise ValueError(f"环境文件第 {line_number} 行无效")
    values[key] = value
  return values


def main() -> None:
  env_file = Path(os.environ.get("SUBFLOW_ENV_FILE", str(DEFAULT_ENV_FILE)))
  values = parse_env_file(env_file.read_text(encoding="utf-8"))
  environment = os.environ.copy()
  environment.update(values)
  install_root = Path(__file__).resolve().parent.parent
  os.chdir(install_root)
  os.execvpe("python3", ["python3", "-m", "subflow"], environment)


if __name__ == "__main__":
  main()