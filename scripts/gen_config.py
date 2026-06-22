#!/usr/bin/env python3
"""
依据 configs/defaults.yaml 生成各语言共享常量文件（纯标准库实现）。

为什么要有这个脚本：
  bash 管理器要求最终产物 sb.sh 是「单文件」，Python 数据 API 要求「纯标准库」，
  因此运行期都不解析 YAML。本脚本在「构建/生成阶段」读取 configs/defaults.yaml，
  把共享默认值固化成各语言可直接 source / import 的常量文件，从而既有「唯一来源」，
  又不给运行期引入额外依赖。

生成目标：
  - vps/singbox/lib/00_generated.sh   （bash，被 build.sh 合并进 sb.sh）
  - vps/subflow/subflow/_defaults.py  （Python，被 paths.py / config.py 导入）

用法：
  python3 scripts/gen_config.py
"""

from pathlib import Path

# 仓库根目录 = 本文件所在的 scripts/ 的上一级。
REPO_ROOT = Path(__file__).resolve().parent.parent
YAML_PATH = REPO_ROOT / "configs" / "defaults.yaml"
BASH_OUT = REPO_ROOT / "vps" / "singbox" / "lib" / "00_generated.sh"
# Python 包根目录就是 vps/subflow（其中直接含 __init__.py），故 _defaults.py 放在此处。
PY_OUT = REPO_ROOT / "vps" / "subflow" / "_defaults.py"


def parse_yaml(text: str) -> dict:
    """
    解析受限子集的 YAML：仅支持「两层结构」——顶层小节 + 两空格缩进的 key: value。

    只为本项目自己的 configs/defaults.yaml 服务，因此不追求通用性：
      - 忽略空行与以 # 开头的整行注释；
      - 行内 # 之后视为注释并丢弃（本项目取值均为路径/端口，不含 #）；
      - 顶层 `name:`（无值）开启一个小节，其下缩进项写入该小节字典。
    """
    data: dict = {}
    section: dict | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        # 跳过空行与整行注释。
        if not stripped or stripped.startswith("#"):
            continue
        if not line.startswith(" "):
            # 顶层小节，例如 "paths:"。
            key = stripped.split(":", 1)[0].strip()
            data[key] = {}
            section = data[key]
        else:
            # 小节内的键值对，例如 "singbox_config: /etc/sing-box/config.json"。
            key, _, value = stripped.partition(":")
            value = value.split("#", 1)[0].strip()  # 去掉行内注释
            if section is not None:
                section[key.strip()] = value
    return data


def render_bash(paths: dict) -> str:
    """生成 bash 共享常量（供 build.sh 合并进 sb.sh）。"""
    lines = [
        "#!/usr/bin/env bash",
        "# 本文件由 scripts/gen_config.py 依据 configs/defaults.yaml 自动生成，请勿手改。",
        f'CONFIG_FILE="{paths["singbox_config"]}"',
        f'USER_DB_FILE="{paths["user_db"]}"',
        f'META_FILE="{paths["meta"]}"',
        f'TG_CONFIG_FILE="{paths["telegram"]}"',
        "",
    ]
    return "\n".join(lines)


def render_python(paths: dict, data_api: dict) -> str:
    """生成 Python 共享常量（供 paths.py / config.py 导入）。"""
    lines = [
        '"""本文件由 scripts/gen_config.py 依据 configs/defaults.yaml 自动生成，请勿手改。"""',
        "",
        f'SINGBOX_CONFIG_PATH = "{paths["singbox_config"]}"',
        f'USER_DB_PATH = "{paths["user_db"]}"',
        f'META_PATH = "{paths["meta"]}"',
        f'TELEGRAM_PATH = "{paths["telegram"]}"',
        f'DATA_API_LISTEN_HOST = "{data_api["listen_host"]}"',
        f'DATA_API_LISTEN_PORT = {int(data_api["listen_port"])}',
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    data = parse_yaml(YAML_PATH.read_text(encoding="utf-8"))
    paths = data["paths"]
    data_api = data["data_api"]

    BASH_OUT.parent.mkdir(parents=True, exist_ok=True)
    PY_OUT.parent.mkdir(parents=True, exist_ok=True)
    BASH_OUT.write_text(render_bash(paths), encoding="utf-8")
    PY_OUT.write_text(render_python(paths, data_api), encoding="utf-8")
    print(f"generated: {BASH_OUT}")
    print(f"generated: {PY_OUT}")


if __name__ == "__main__":
    main()
