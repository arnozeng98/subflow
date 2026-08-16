#!/usr/bin/env python3
"""依据依赖锁生成部署与 sing-box 管理器使用的 Shell 常量。"""

import json
from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = REPO_ROOT / "configs" / "dependencies.lock.json"
DEPLOY_SHELL_OUT = REPO_ROOT / "vps" / "deploy" / "dependencies.sh"
SINGBOX_SHELL_OUT = REPO_ROOT / "vps" / "singbox" / "lib" / "00_dependencies.sh"


def _require_string(payload: dict, key: str, pattern: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError(f"依赖锁字段无效: {key}")
    return value


def render_shell(payload: dict) -> str:
    if payload.get("schema_version") != 1:
        raise ValueError("不支持的依赖锁版本")

    wrangler = payload.get("wrangler")
    cloudflared = payload.get("cloudflared")
    if not isinstance(wrangler, dict) or not isinstance(cloudflared, dict):
        raise ValueError("依赖锁缺少 wrangler 或 cloudflared")

    wrangler_version = _require_string(wrangler, "version", r"[0-9]+(?:\.[0-9]+){2}")
    wrangler_integrity = _require_string(wrangler, "integrity", r"sha512-[A-Za-z0-9+/=]+")
    node_min_major = wrangler.get("node_min_major")
    if type(node_min_major) is not int or node_min_major < 1:
        raise ValueError("依赖锁字段无效: node_min_major")

    cloudflared_version = _require_string(cloudflared, "version", r"[0-9]+(?:\.[0-9]+){2}")
    hashes = cloudflared.get("sha256")
    if not isinstance(hashes, dict):
        raise ValueError("依赖锁缺少 cloudflared.sha256")
    architecture_hashes = {
        architecture: _require_string(hashes, architecture, r"[0-9a-f]{64}")
        for architecture in ("amd64", "arm64", "arm")
    }

    return "\n".join((
        "#!/usr/bin/env bash",
        "# 本文件由 scripts/gen_dependencies.py 依据 configs/dependencies.lock.json 自动生成，请勿手改。",
        f'WRANGLER_VERSION="{wrangler_version}"',
        f'WRANGLER_NODE_MIN_MAJOR="{node_min_major}"',
        f'WRANGLER_INTEGRITY="{wrangler_integrity}"',
        f'CLOUDFLARED_VERSION="{cloudflared_version}"',
        "declare -A CLOUDFLARED_SHA256=(",
        f'  [amd64]="{architecture_hashes["amd64"]}"',
        f'  [arm64]="{architecture_hashes["arm64"]}"',
        f'  [arm]="{architecture_hashes["arm"]}"',
        ")",
        "",
    ))


def render_singbox_shell(payload: dict) -> str:
    if payload.get("schema_version") != 1:
        raise ValueError("不支持的依赖锁版本")

    grpcurl = payload.get("grpcurl")
    if not isinstance(grpcurl, dict):
        raise ValueError("依赖锁缺少 grpcurl")
    version = _require_string(grpcurl, "version", r"[0-9]+(?:\.[0-9]+){2}")
    hashes = grpcurl.get("sha256")
    if not isinstance(hashes, dict):
        raise ValueError("依赖锁缺少 grpcurl.sha256")
    architecture_hashes = {
        architecture: _require_string(hashes, architecture, r"[0-9a-f]{64}")
        for architecture in ("x86_64", "arm64")
    }

    return "\n".join((
        "#!/usr/bin/env bash",
        "# 本文件由 scripts/gen_dependencies.py 依据 configs/dependencies.lock.json 自动生成，请勿手改。",
        f'GRPCURL_VERSION="{version}"',
        "declare -A GRPCURL_SHA256=(",
        f'  [x86_64]="{architecture_hashes["x86_64"]}"',
        f'  [arm64]="{architecture_hashes["arm64"]}"',
        ")",
        "",
    ))


def main() -> int:
    try:
        payload = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        outputs = {
            DEPLOY_SHELL_OUT: render_shell(payload),
            SINGBOX_SHELL_OUT: render_singbox_shell(payload),
        }
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(f"依赖锁无效: {error}", file=sys.stderr)
        return 2

    if "--check" in sys.argv[1:]:
        mismatches = []
        for output_path, expected in outputs.items():
            try:
                actual = output_path.read_text(encoding="utf-8")
            except OSError:
                actual = ""
            if actual != expected:
                mismatches.append(output_path)
        if mismatches:
            for output_path in mismatches:
                print(f"需要重新生成: {output_path}", file=sys.stderr)
            return 1
        print("依赖常量文件均为最新状态")
        return 0

    if sys.argv[1:]:
        print(f"未知参数: {' '.join(sys.argv[1:])}", file=sys.stderr)
        return 2

    for output_path, content in outputs.items():
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(content, encoding="utf-8")
        print(f"已生成: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())