#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

# ============================================================
# subflow 共享终端主题
# ============================================================
# 所有部署与管理脚本共用的颜色、状态输出、暂停提示和品牌横幅。
# ============================================================

setup_colors() {
  local ncolors=0
  if command -v tput >/dev/null 2>&1; then
    ncolors="$(tput colors 2>/dev/null || printf '0')"
  fi
  if [[ -t 1 && "${ncolors}" -ge 8 && "${NO_COLOR:-}" == "" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_PINK=$'\033[38;5;218m'
    C_LAV=$'\033[38;5;183m'
    C_CYAN=$'\033[38;5;117m'
    C_GREEN=$'\033[38;5;151m'
    C_YELLOW=$'\033[38;5;229m'
    C_RED=$'\033[38;5;210m'
    C_GREY=$'\033[38;5;246m'
  else
    C_RESET="" C_BOLD="" C_DIM="" C_PINK="" C_LAV="" C_CYAN=""
    C_GREEN="" C_YELLOW="" C_RED="" C_GREY=""
  fi
}
setup_colors

ok()   { printf '%b\n' "  ${C_GREEN}(๑˃ᴗ˂)ﻭ  $1${C_RESET}"; }
info() { printf '%b\n' "  ${C_CYAN}(｡･ω･)ﾉ  $1${C_RESET}"; }
note() { printf '%b\n' "  ${C_GREY}(・∀・)    $1${C_RESET}"; }
warn() { printf '%b\n' "  ${C_YELLOW}(・_・;)   $1${C_RESET}"; }
err()  { printf '%b\n' "  ${C_RED}(╥﹏╥)    $1${C_RESET}" >&2; }
step() { printf '%b\n' "  ${C_PINK}♡ $1${C_RESET}"; }

pause() {
  printf '%b' "  ${C_GREY}按回车继续…${C_RESET}"
  read -r _ || true
}

banner() {
  printf '%b\n' ""
  printf '%b\n' "${C_PINK}  ███████╗██╗   ██╗██████╗ ███████╗██╗      ██████╗ ██╗    ██╗${C_RESET}"
  printf '%b\n' "${C_PINK}  ██╔════╝██║   ██║██╔══██╗██╔════╝██║     ██╔═══██╗██║    ██║${C_RESET}"
  printf '%b\n' "${C_LAV}  ███████╗██║   ██║██████╔╝█████╗  ██║     ██║   ██║██║ █╗ ██║${C_RESET}"
  printf '%b\n' "${C_LAV}  ╚════██║██║   ██║██╔══██╗██╔══╝  ██║     ██║   ██║██║███╗██║${C_RESET}"
  printf '%b\n' "${C_CYAN}  ███████║╚██████╔╝██████╔╝██║     ███████╗╚██████╔╝╚███╔███╔╝${C_RESET}"
  printf '%b\n' "${C_CYAN}  ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝ ${C_RESET}"
  printf '%b\n' ""
  printf '%b\n' "  ${C_BOLD}SUBFLOW${C_RESET} ${C_GREY}· 由 Cloudflare 提供前端的逐用户 sing-box 订阅${C_RESET}"
  printf '%b\n' "  ${C_PINK}♡${C_RESET} ${C_BOLD}作者${C_RESET} ${C_LAV}${AUTHOR:-未知}${C_RESET}   ${C_PINK}♡${C_RESET} ${C_BOLD}仓库${C_RESET} ${C_CYAN}${REPO_URL:-未设置}${C_RESET}"
  printf '%b\n' "  ${C_GREY}────────────────────────────────────────────────────${C_RESET}"
}

subflow_release_manifest() {
  if [[ -n "${SUBFLOW_RELEASE_MANIFEST_PATH:-}" ]]; then
    cat -- "$SUBFLOW_RELEASE_MANIFEST_PATH"
    return
  fi
  cat <<'SUBFLOW_RELEASE_MANIFEST_JSON'
{
  "schema_version": 1,
  "repository": "arnozeng98/subflow",
  "latest": "1.13.18",
  "releases": {
    "1.13.18": {
      "upstream_repository": "SagerNet/sing-box",
      "upstream_tag": "v1.13.18",
      "assets": {
        "amd64": {
          "name": "sing-box-linux-amd64",
          "sha256": "ae4e9065625c2eb0f88a9de8c4ca8927fec90e32e983756252e09ddd402dc72a"
        },
        "arm64": {
          "name": "sing-box-linux-arm64",
          "sha256": "5f92825d4073accb270dbeebdf55d4b3fabba99dcec05177de26d8e7811bda3d"
        }
      }
    }
  }
}
SUBFLOW_RELEASE_MANIFEST_JSON
}

subflow_reality_mutator_source() {
  cat <<'SUBFLOW_REALITY_MUTATOR_PY'
import json
import sys
import uuid
from pathlib import Path


def load_object(path: str) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON 不是对象: {path}")
    return value


def is_reality(inbound: dict) -> bool:
    return (
        inbound.get("type") == "vless"
        and isinstance(inbound.get("tls"), dict)
        and isinstance(inbound["tls"].get("reality"), dict)
        and inbound["tls"]["reality"].get("enabled") is True
    )


def add_reality(
    config: dict,
    meta: dict,
    users_payload: dict,
    tag: str,
    port: int,
    server_name: str,
    handshake_server: str,
    handshake_port: int,
    private_key: str,
    public_key: str,
    short_id: str,
) -> None:
    inbounds = config["inbounds"]
    if any(item.get("tag") == tag for item in inbounds):
        raise ValueError(f"协议标签已存在: {tag}")
    if any(item.get("listen_port") == port for item in inbounds):
        raise ValueError(f"端口已被占用: {port}")
    users = users_payload.get("users")
    if not isinstance(users, dict):
        raise ValueError("用户库结构错误")
    inbound_users = []
    for username, user in sorted(users.items()):
        if not isinstance(user, dict) or user.get("enabled", True) is not True:
            continue
        if not user.get("allow_all_nodes", True) and tag not in user.get("nodes", []):
            continue
        inbound_users.append(
            {
                "name": f"{tag}@{username}",
                "uuid": str(uuid.uuid4()),
                "flow": "xtls-rprx-vision",
            }
        )
    if not inbound_users:
        raise ValueError("没有可加入该协议的启用用户")
    inbounds.append(
        {
            "type": "vless",
            "tag": tag,
            "listen": "::",
            "listen_port": port,
            "users": inbound_users,
            "tls": {
                "enabled": True,
                "server_name": server_name,
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": handshake_server,
                        "server_port": handshake_port,
                    },
                    "private_key": private_key,
                    "short_id": [short_id],
                },
            },
        }
    )
    meta[tag] = {"public_key": public_key}


def update_reality(
    config: dict,
    meta: dict,
    tag: str,
    port_text: str,
    server_name: str,
    handshake_server: str,
    handshake_port_text: str,
) -> None:
    inbounds = config["inbounds"]
    matches = [item for item in inbounds if item.get("tag") == tag]
    if len(matches) != 1 or not is_reality(matches[0]):
        raise ValueError(f"未知 VLESS Reality 协议: {tag}")
    public_meta = meta.get(tag)
    if not isinstance(public_meta, dict) or not isinstance(public_meta.get("public_key"), str):
        raise ValueError(f"VLESS Reality 公钥元数据缺失: {tag}")
    inbound = matches[0]
    if port_text:
        port = int(port_text)
        if any(item.get("tag") != tag and item.get("listen_port") == port for item in inbounds):
            raise ValueError(f"端口已被占用: {port}")
        inbound["listen_port"] = port
    tls = inbound["tls"]
    reality = tls["reality"]
    handshake = reality.setdefault("handshake", {})
    if server_name:
        tls["server_name"] = server_name
    if handshake_server:
        handshake["server"] = handshake_server
    if handshake_port_text:
        handshake["server_port"] = int(handshake_port_text)


def delete_reality(config: dict, meta: dict, tag: str) -> None:
    inbounds = config["inbounds"]
    matches = [item for item in inbounds if item.get("tag") == tag]
    if len(matches) != 1 or not is_reality(matches[0]):
        raise ValueError(f"未知 VLESS Reality 协议: {tag}")
    config["inbounds"] = [item for item in inbounds if item.get("tag") != tag]
    meta.pop(tag, None)


def main() -> None:
    (
        operation,
        config_file,
        meta_file,
        users_file,
        tag,
        port_text,
        server_name,
        handshake_server,
        handshake_port_text,
        private_key,
        public_key,
        short_id,
    ) = sys.argv[1:]
    config = load_object(config_file)
    meta = load_object(meta_file)
    users_payload = load_object(users_file)
    inbounds = config.setdefault("inbounds", [])
    if not isinstance(inbounds, list):
        raise ValueError("config.inbounds 不是数组")

    if operation == "add":
        add_reality(
            config,
            meta,
            users_payload,
            tag,
            int(port_text),
            server_name,
            handshake_server,
            int(handshake_port_text),
            private_key,
            public_key,
            short_id,
        )
    elif operation == "update":
        update_reality(
            config,
            meta,
            tag,
            port_text,
            server_name,
            handshake_server,
            handshake_port_text,
        )
    elif operation == "delete":
        delete_reality(config, meta, tag)
    else:
        raise ValueError(f"未知协议操作: {operation}")

    config["inbounds"] = sorted(config["inbounds"], key=lambda item: str(item.get("tag", "")))
    Path(config_file).write_text(
        json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    Path(meta_file).write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
SUBFLOW_REALITY_MUTATOR_PY
}

subflow_shadowsocks_mutator_source() {
  cat <<'SUBFLOW_SHADOWSOCKS_MUTATOR_PY'
import base64
import json
import secrets
import sys
from pathlib import Path


KEY_LENGTHS = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
}


def load_object(path: str) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON 不是对象: {path}")
    return value


def password(key_length: int) -> str:
    return base64.b64encode(secrets.token_bytes(key_length)).decode("ascii")


def is_shadowsocks_2022(inbound: dict) -> bool:
    return inbound.get("type") == "shadowsocks" and inbound.get("method") in KEY_LENGTHS


def add_shadowsocks(
    config: dict,
    users_payload: dict,
    tag: str,
    port: int,
    method: str,
) -> None:
    inbounds = config["inbounds"]
    if method not in KEY_LENGTHS:
        raise ValueError(f"不支持的 Shadowsocks 2022 方法: {method}")
    if any(item.get("tag") == tag for item in inbounds):
        raise ValueError(f"协议标签已存在: {tag}")
    if any(item.get("listen_port") == port for item in inbounds):
        raise ValueError(f"端口已被占用: {port}")
    users = users_payload.get("users")
    if not isinstance(users, dict):
        raise ValueError("用户库结构错误")
    inbound_users = []
    for username, user in sorted(users.items()):
        if not isinstance(user, dict) or user.get("enabled", True) is not True:
            continue
        if not user.get("allow_all_nodes", True) and tag not in user.get("nodes", []):
            continue
        inbound_users.append(
            {
                "name": f"{tag}@{username}",
                "password": password(KEY_LENGTHS[method]),
            }
        )
    if not inbound_users:
        raise ValueError("没有可加入该协议的启用用户")
    inbounds.append(
        {
            "type": "shadowsocks",
            "tag": tag,
            "listen": "::",
            "listen_port": port,
            "network": "tcp",
            "method": method,
            "password": password(KEY_LENGTHS[method]),
            "users": inbound_users,
            "multiplex": {"enabled": True},
        }
    )


def update_shadowsocks(config: dict, tag: str, port_text: str) -> None:
    inbounds = config["inbounds"]
    matches = [item for item in inbounds if item.get("tag") == tag]
    if len(matches) != 1 or not is_shadowsocks_2022(matches[0]):
        raise ValueError(f"未知 Shadowsocks 2022 协议: {tag}")
    if port_text:
        port = int(port_text)
        if any(item.get("tag") != tag and item.get("listen_port") == port for item in inbounds):
            raise ValueError(f"端口已被占用: {port}")
        matches[0]["listen_port"] = port


def delete_shadowsocks(config: dict, tag: str) -> None:
    inbounds = config["inbounds"]
    matches = [item for item in inbounds if item.get("tag") == tag]
    if len(matches) != 1 or not is_shadowsocks_2022(matches[0]):
        raise ValueError(f"未知 Shadowsocks 2022 协议: {tag}")
    config["inbounds"] = [item for item in inbounds if item.get("tag") != tag]


def main() -> None:
    operation, config_file, meta_file, users_file, tag, port_text, method = sys.argv[1:]
    config = load_object(config_file)
    meta = load_object(meta_file)
    users_payload = load_object(users_file)
    inbounds = config.setdefault("inbounds", [])
    if not isinstance(inbounds, list):
        raise ValueError("config.inbounds 不是数组")

    if operation == "add":
        add_shadowsocks(config, users_payload, tag, int(port_text), method)
    elif operation == "update":
        update_shadowsocks(config, tag, port_text)
    elif operation == "delete":
        delete_shadowsocks(config, tag)
    else:
        raise ValueError(f"未知协议操作: {operation}")

    config["inbounds"] = sorted(config["inbounds"], key=lambda item: str(item.get("tag", "")))
    Path(config_file).write_text(
        json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    Path(meta_file).write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
SUBFLOW_SHADOWSOCKS_MUTATOR_PY
}

subflow_user_config_mutator_source() {
  cat <<'SUBFLOW_USER_CONFIG_MUTATOR_PY'
import base64
import json
import secrets
import sys
import uuid
from pathlib import Path


SHADOWSOCKS_KEY_LENGTHS = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
}
CONFIG_OPERATIONS = {"add", "enable", "disable", "delete"}


def load_object(path: str) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON 不是对象: {path}")
    return value


def credential_owner(name: object) -> str:
    if not isinstance(name, str):
        return ""
    return name.split("@", 1)[1] if "@" in name else "admin"


def is_reality(inbound: dict) -> bool:
    return (
        inbound.get("type") == "vless"
        and isinstance(inbound.get("tls"), dict)
        and isinstance(inbound["tls"].get("reality"), dict)
        and inbound["tls"]["reality"].get("enabled") is True
    )


def is_shadowsocks_2022(inbound: dict) -> bool:
    return (
        inbound.get("type") == "shadowsocks"
        and inbound.get("method") in SHADOWSOCKS_KEY_LENGTHS
    )


def is_password_tls_inbound(inbound: dict) -> bool:
    return inbound.get("type") in {"anytls", "trojan"}


def is_tuic(inbound: dict) -> bool:
    return inbound.get("type") == "tuic"


def is_managed_inbound(inbound: dict) -> bool:
    return (
        is_reality(inbound)
        or is_shadowsocks_2022(inbound)
        or is_password_tls_inbound(inbound)
        or is_tuic(inbound)
    )


def user_can_access(user: dict, tag: str) -> bool:
    if user.get("enabled", True) is not True:
        return False
    if user.get("allow_all_nodes", True) is True:
        return True
    nodes = user.get("nodes", [])
    return isinstance(nodes, list) and tag in nodes


def generate_password(key_length: int) -> str:
    return base64.b64encode(secrets.token_bytes(key_length)).decode("ascii")


def add_credential(inbound: dict, username: str) -> None:
    tag = inbound.get("tag")
    if not isinstance(tag, str) or not tag:
        raise ValueError("受管入站缺少标签")
    users = inbound.get("users")
    if not isinstance(users, list):
        raise ValueError(f"受管入站用户结构错误: {tag}")
    if is_reality(inbound):
        users.append(
            {
                "name": f"{tag}@{username}",
                "uuid": str(uuid.uuid4()),
                "flow": "xtls-rprx-vision",
            }
        )
        return
    if is_password_tls_inbound(inbound):
        users.append(
            {
                "name": f"{tag}@{username}",
                "password": secrets.token_urlsafe(24),
            }
        )
        return
    if is_tuic(inbound):
        users.append(
            {
                "name": f"{tag}@{username}",
                "uuid": str(uuid.uuid4()),
                "password": secrets.token_urlsafe(24),
            }
        )
        return
    method = inbound["method"]
    users.append(
        {
            "name": f"{tag}@{username}",
            "password": generate_password(SHADOWSOCKS_KEY_LENGTHS[method]),
        }
    )


def mutate(operation: str, config: dict, users_payload: dict, username: str) -> None:
    if operation not in CONFIG_OPERATIONS:
        return
    inbounds = config.get("inbounds")
    if not isinstance(inbounds, list):
        raise ValueError("config.inbounds 不是数组")
    users = users_payload.get("users")
    if not isinstance(users, dict):
        raise ValueError("用户库结构错误")

    for inbound in inbounds:
        if not isinstance(inbound, dict) or not is_managed_inbound(inbound):
            continue
        inbound_users = inbound.get("users")
        if not isinstance(inbound_users, list):
            raise ValueError(f"受管入站用户结构错误: {inbound.get('tag', '')}")
        inbound["users"] = [
            credential
            for credential in inbound_users
            if credential_owner(credential.get("name") if isinstance(credential, dict) else None)
            != username
        ]

    if operation not in {"add", "enable"}:
        return
    user = users.get(username)
    if not isinstance(user, dict):
        raise ValueError(f"候选用户不存在: {username}")
    for inbound in inbounds:
        if not isinstance(inbound, dict) or not is_managed_inbound(inbound):
            continue
        tag = inbound.get("tag")
        if isinstance(tag, str) and user_can_access(user, tag):
            add_credential(inbound, username)


def main() -> None:
    operation, config_file, users_file, username = sys.argv[1:]
    config = load_object(config_file)
    users_payload = load_object(users_file)
    mutate(operation, config, users_payload, username)
    Path(config_file).write_text(
        json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
SUBFLOW_USER_CONFIG_MUTATOR_PY
}

subflow_user_transaction_manifest_source() {
  cat <<'SUBFLOW_USER_TRANSACTION_MANIFEST_PY'
import json
import sys
from pathlib import Path


BOOLEAN_FIELDS = {
    "users_existed",
    "index_existed",
    "config_existed",
    "config_changed",
    "service_existed",
    "service_was_active",
}
FIELD_DEFAULTS = {
    "config_existed": False,
    "config_changed": False,
    "service_existed": False,
    "service_was_active": False,
    "config_target": "",
    "service_target": "",
    "init": "",
}


def boolean(value: str) -> bool:
    if value not in {"true", "false"}:
        raise ValueError("布尔参数不合法")
    return value == "true"


def load(path: str) -> dict:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("恢复清单不是对象")
    return payload


def write_manifest(arguments: list[str]) -> None:
    (
        manifest_file,
        txn_dir,
        state_dir,
        users_target,
        index_target,
        config_target,
        service_target,
        init,
        operation,
        username,
        users_existed,
        index_existed,
        config_existed,
        config_changed,
        service_existed,
        service_was_active,
    ) = arguments
    payload = {
        "version": 2,
        "kind": "user-config",
        "txn_dir": txn_dir,
        "state_dir": state_dir,
        "users_target": users_target,
        "index_target": index_target,
        "config_target": config_target,
        "service_target": service_target,
        "init": init,
        "operation": operation,
        "username": username,
        "users_backup": "backup/users.json",
        "index_backup": "backup/subscriptions.json",
        "config_backup": "backup/config.json",
        "users_existed": boolean(users_existed),
        "index_existed": boolean(index_existed),
        "config_existed": boolean(config_existed),
        "config_changed": boolean(config_changed),
        "service_existed": boolean(service_existed),
        "service_was_active": boolean(service_was_active),
    }
    Path(manifest_file).write_text(
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def validate_v1(payload: dict, expected: dict) -> None:
    required = {
        "version": 1,
        "txn_dir": expected["txn_dir"],
        "state_dir": expected["state_dir"],
        "users_target": expected["users_target"],
        "index_target": expected["index_target"],
        "users_backup": "backup/users.json",
        "index_backup": "backup/subscriptions.json",
    }
    if any(payload.get(key) != value for key, value in required.items()):
        raise ValueError("v1 清单字段不匹配")
    for field in ("users_existed", "index_existed"):
        if type(payload.get(field)) is not bool:
            raise ValueError(f"v1 清单字段类型错误: {field}")


def validate_v2(payload: dict, expected: dict) -> None:
    required = {
        "version": 2,
        "kind": "user-config",
        "txn_dir": expected["txn_dir"],
        "state_dir": expected["state_dir"],
        "users_target": expected["users_target"],
        "index_target": expected["index_target"],
        "config_target": expected["config_target"],
        "service_target": expected["service_target"],
        "users_backup": "backup/users.json",
        "index_backup": "backup/subscriptions.json",
        "config_backup": "backup/config.json",
    }
    if any(payload.get(key) != value for key, value in required.items()):
        raise ValueError("v2 清单字段不匹配")
    if payload.get("init") not in {"systemd", "openrc"}:
        raise ValueError("v2 清单 init 不合法")
    if not isinstance(payload.get("operation"), str) or not isinstance(payload.get("username"), str):
        raise ValueError("v2 清单操作字段不合法")
    for field in BOOLEAN_FIELDS:
        if type(payload.get(field)) is not bool:
            raise ValueError(f"v2 清单字段类型错误: {field}")
    if payload["config_changed"] and (not payload["config_existed"] or not payload["service_existed"]):
        raise ValueError("配置变更缺少原配置或服务定义")


def validate_manifest(arguments: list[str]) -> None:
    manifest_file, txn_dir, state_dir, users_target, index_target, config_target, service_target = arguments
    payload = load(manifest_file)
    expected = {
        "txn_dir": txn_dir,
        "state_dir": state_dir,
        "users_target": users_target,
        "index_target": index_target,
        "config_target": config_target,
        "service_target": service_target,
    }
    if payload.get("version") == 1:
        validate_v1(payload, expected)
    elif payload.get("version") == 2:
        validate_v2(payload, expected)
    else:
        raise ValueError("不支持的用户事务清单版本")


def print_field(arguments: list[str]) -> None:
    manifest_file, field = arguments
    allowed = BOOLEAN_FIELDS | {
        "version",
        "config_target",
        "service_target",
        "init",
    }
    if field not in allowed:
        raise ValueError("不允许读取该清单字段")
    payload = load(manifest_file)
    value = payload.get(field, FIELD_DEFAULTS.get(field))
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (int, str)):
        print(value)
    else:
        raise ValueError("清单字段类型错误")


def main() -> None:
    command, *arguments = sys.argv[1:]
    if command == "write":
        write_manifest(arguments)
    elif command == "validate":
        validate_manifest(arguments)
    elif command == "field":
        print_field(arguments)
    else:
        raise ValueError("未知用户事务清单命令")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
SUBFLOW_USER_TRANSACTION_MANIFEST_PY
}

subflow_acme_secret_source() {
  cat <<'SUBFLOW_ACME_SECRET_PY'
import json
import re
import sys
from pathlib import Path


TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{20,256}$")
ROTATION_BOOLEAN_FIELDS = {"secret_existed", "service_was_active"}


def read_token(path_text: str, label: str) -> str:
    path = Path(path_text)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} 文件必须是普通文件")
    raw = path.read_bytes()
    if not raw or len(raw) > 4096:
        raise ValueError(f"{label} 文件大小不合法")
    try:
        token = raw.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} 必须是 ASCII") from error
    if not TOKEN_PATTERN.fullmatch(token):
        raise ValueError(f"{label} 格式不合法")
    return token


def load_secret(path_text: str) -> dict:
    path = Path(path_text)
    if path.is_symlink() or not path.is_file():
        raise ValueError("Cloudflare ACME 凭据文件不可信")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or set(payload) - {"api_token", "zone_token"}:
        raise ValueError("Cloudflare ACME 凭据结构错误")
    api_token = payload.get("api_token")
    zone_token = payload.get("zone_token")
    if not isinstance(api_token, str) or not TOKEN_PATTERN.fullmatch(api_token):
        raise ValueError("Cloudflare API Token 格式错误")
    if zone_token is not None and (
        not isinstance(zone_token, str) or not TOKEN_PATTERN.fullmatch(zone_token)
    ):
        raise ValueError("Cloudflare Zone Token 格式错误")
    return payload


def create_secret(arguments: list[str]) -> None:
    api_token_file, zone_token_file, output_file = arguments
    payload = {"api_token": read_token(api_token_file, "Cloudflare API Token")}
    if zone_token_file != "-":
        payload["zone_token"] = read_token(zone_token_file, "Cloudflare Zone Token")
    Path(output_file).write_text(
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def print_field(arguments: list[str]) -> None:
    secret_file, field = arguments
    if field not in {"api_token", "zone_token"}:
        raise ValueError("不允许读取该 ACME 字段")
    value = load_secret(secret_file).get(field, "")
    print(value)


def config_uses_cloudflare(path_text: str) -> bool:
    path = Path(path_text)
    if not path.is_file():
        return False
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("sing-box 配置不是对象")
    inbounds = config.get("inbounds", [])
    if not isinstance(inbounds, list):
        raise ValueError("config.inbounds 不是数组")
    for inbound in inbounds:
        if not isinstance(inbound, dict):
            continue
        tls = inbound.get("tls")
        acme = tls.get("acme") if isinstance(tls, dict) else None
        challenge = acme.get("dns01_challenge") if isinstance(acme, dict) else None
        if isinstance(challenge, dict) and challenge.get("provider") == "cloudflare":
            return True
    return False


def write_json(path_text: str, payload: dict) -> None:
    Path(path_text).write_text(
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def rewrite_config(arguments: list[str]) -> None:
    source_file, secret_file, output_file = arguments
    config = json.loads(Path(source_file).read_text(encoding="utf-8"))
    if not isinstance(config, dict) or not isinstance(config.get("inbounds"), list):
        raise ValueError("sing-box 配置结构错误")
    secret = load_secret(secret_file)
    updated = 0
    for inbound in config["inbounds"]:
        if not isinstance(inbound, dict):
            continue
        tls = inbound.get("tls")
        acme = tls.get("acme") if isinstance(tls, dict) else None
        challenge = acme.get("dns01_challenge") if isinstance(acme, dict) else None
        if not isinstance(challenge, dict) or challenge.get("provider") != "cloudflare":
            continue
        challenge["api_token"] = secret["api_token"]
        if secret.get("zone_token"):
            challenge["zone_token"] = secret["zone_token"]
        else:
            challenge.pop("zone_token", None)
        updated += 1
    if updated == 0:
        raise ValueError("配置中没有 Cloudflare ACME 引用")
    write_json(output_file, config)


def write_rotation_manifest(arguments: list[str]) -> None:
    (
        manifest_file,
        txn_dir,
        state_dir,
        config_target,
        secret_target,
        service_target,
        init,
        secret_existed,
        service_was_active,
    ) = arguments
    if init not in {"systemd", "openrc"}:
        raise ValueError("ACME 轮换 init 不合法")
    payload = {
        "version": 1,
        "kind": "cloudflare-acme-rotation",
        "txn_dir": txn_dir,
        "state_dir": state_dir,
        "config_target": config_target,
        "secret_target": secret_target,
        "service_target": service_target,
        "init": init,
        "config_backup": "backup/config.json",
        "secret_backup": "backup/cloudflare-acme.json",
        "secret_existed": secret_existed == "true",
        "service_was_active": service_was_active == "true",
    }
    if secret_existed not in {"true", "false"} or service_was_active not in {"true", "false"}:
        raise ValueError("ACME 轮换布尔参数不合法")
    write_json(manifest_file, payload)


def validate_rotation_manifest(arguments: list[str]) -> None:
    manifest_file, txn_dir, state_dir, config_target, secret_target, service_target = arguments
    payload = json.loads(Path(manifest_file).read_text(encoding="utf-8"))
    expected = {
        "version": 1,
        "kind": "cloudflare-acme-rotation",
        "txn_dir": txn_dir,
        "state_dir": state_dir,
        "config_target": config_target,
        "secret_target": secret_target,
        "service_target": service_target,
        "config_backup": "backup/config.json",
        "secret_backup": "backup/cloudflare-acme.json",
    }
    if not isinstance(payload, dict) or any(payload.get(key) != value for key, value in expected.items()):
        raise ValueError("ACME 轮换清单字段不匹配")
    if payload.get("init") not in {"systemd", "openrc"}:
        raise ValueError("ACME 轮换清单 init 不合法")
    for field in ROTATION_BOOLEAN_FIELDS:
        if type(payload.get(field)) is not bool:
            raise ValueError(f"ACME 轮换清单字段类型错误: {field}")


def print_rotation_field(arguments: list[str]) -> None:
    manifest_file, field = arguments
    if field not in ROTATION_BOOLEAN_FIELDS | {"init", "service_target"}:
        raise ValueError("不允许读取该 ACME 轮换字段")
    payload = json.loads(Path(manifest_file).read_text(encoding="utf-8"))
    value = payload[field]
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, str):
        print(value)
    else:
        raise ValueError("ACME 轮换字段类型错误")


def main() -> None:
    command, *arguments = sys.argv[1:]
    if command == "create":
        create_secret(arguments)
    elif command == "validate":
        load_secret(arguments[0])
    elif command == "field":
        print_field(arguments)
    elif command == "config-uses-cloudflare":
        raise SystemExit(0 if config_uses_cloudflare(arguments[0]) else 1)
    elif command == "config-state":
        print("used" if config_uses_cloudflare(arguments[0]) else "unused")
    elif command == "rewrite-config":
        rewrite_config(arguments)
    elif command == "rotation-manifest-write":
        write_rotation_manifest(arguments)
    elif command == "rotation-manifest-validate":
        validate_rotation_manifest(arguments)
    elif command == "rotation-manifest-field":
        print_rotation_field(arguments)
    else:
        raise ValueError("未知 ACME 凭据命令")


if __name__ == "__main__":
    try:
        main()
    except (IndexError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
SUBFLOW_ACME_SECRET_PY
}

subflow_tls_protocol_mutator_source() {
  cat <<'SUBFLOW_TLS_PROTOCOL_MUTATOR_PY'
import json
import re
import secrets
import sys
import uuid
from pathlib import Path


PROTOCOL_TYPES = {
    "anytls": "anytls",
    "trojan": "trojan",
    "tuic": "tuic",
}
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{20,256}$")


def load_object(path: str) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON 不是对象: {path}")
    return value


def load_acme_secret(path_text: str) -> dict:
    path = Path(path_text)
    if path.is_symlink() or not path.is_file():
        raise ValueError("Cloudflare ACME 凭据未配置")
    payload = load_object(path_text)
    api_token = payload.get("api_token")
    zone_token = payload.get("zone_token")
    if not isinstance(api_token, str) or not TOKEN_PATTERN.fullmatch(api_token):
        raise ValueError("Cloudflare API Token 格式错误")
    if zone_token is not None and (
        not isinstance(zone_token, str) or not TOKEN_PATTERN.fullmatch(zone_token)
    ):
        raise ValueError("Cloudflare Zone Token 格式错误")
    return payload


def acme_tls(domain: str, email: str, secret: dict, data_directory: str) -> dict:
    dns01_challenge = {
        "provider": "cloudflare",
        "api_token": secret["api_token"],
    }
    if secret.get("zone_token"):
        dns01_challenge["zone_token"] = secret["zone_token"]
    return {
        "enabled": True,
        "server_name": domain,
        "acme": {
            "domain": [domain],
            "data_directory": data_directory,
            "default_server_name": domain,
            "email": email,
            "provider": "letsencrypt",
            "dns01_challenge": dns01_challenge,
        },
    }


def user_allowed(user: dict, tag: str) -> bool:
    if user.get("enabled", True) is not True:
        return False
    if user.get("allow_all_nodes", True) is True:
        return True
    nodes = user.get("nodes", [])
    return isinstance(nodes, list) and tag in nodes


def credential(protocol: str, tag: str, username: str) -> dict:
    result = {
        "name": f"{tag}@{username}",
        "password": secrets.token_urlsafe(24),
    }
    if protocol == "tuic":
        result["uuid"] = str(uuid.uuid4())
    return result


def is_protocol(inbound: dict, protocol: str) -> bool:
    return inbound.get("type") == PROTOCOL_TYPES[protocol]


def add_protocol(
    config: dict,
    users_payload: dict,
    protocol: str,
    tag: str,
    port: int,
    domain: str,
    email: str,
    secret: dict,
    data_directory: str,
) -> None:
    inbounds = config["inbounds"]
    if any(item.get("tag") == tag for item in inbounds):
        raise ValueError(f"协议标签已存在: {tag}")
    if any(item.get("listen_port") == port for item in inbounds):
        raise ValueError(f"端口已被占用: {port}")
    users = users_payload.get("users")
    if not isinstance(users, dict):
        raise ValueError("用户库结构错误")
    inbound_users = [
        credential(protocol, tag, username)
        for username, user in sorted(users.items())
        if isinstance(user, dict) and user_allowed(user, tag)
    ]
    if not inbound_users:
        raise ValueError("没有可加入该协议的启用用户")
    inbound = {
        "type": PROTOCOL_TYPES[protocol],
        "tag": tag,
        "listen": "::",
        "listen_port": port,
        "users": inbound_users,
        "tls": acme_tls(domain, email, secret, data_directory),
    }
    if protocol == "trojan":
        inbound["multiplex"] = {"enabled": True}
    elif protocol == "tuic":
        inbound.update(
            {
                "congestion_control": "cubic",
                "auth_timeout": "3s",
                "zero_rtt_handshake": False,
                "heartbeat": "10s",
            }
        )
    inbounds.append(inbound)


def update_protocol(
    config: dict,
    protocol: str,
    tag: str,
    port_text: str,
    domain: str,
    email: str,
    secret: dict,
    data_directory: str,
) -> None:
    inbounds = config["inbounds"]
    matches = [item for item in inbounds if item.get("tag") == tag]
    if len(matches) != 1 or not is_protocol(matches[0], protocol):
        raise ValueError(f"未知 {protocol} 协议: {tag}")
    inbound = matches[0]
    if port_text:
        port = int(port_text)
        if any(item.get("tag") != tag and item.get("listen_port") == port for item in inbounds):
            raise ValueError(f"端口已被占用: {port}")
        inbound["listen_port"] = port
    current_tls = inbound.get("tls")
    if not isinstance(current_tls, dict) or not isinstance(current_tls.get("acme"), dict):
        raise ValueError(f"{protocol} ACME 配置缺失: {tag}")
    next_domain = domain or current_tls.get("server_name")
    next_email = email or current_tls["acme"].get("email")
    if not isinstance(next_domain, str) or not isinstance(next_email, str):
        raise ValueError(f"{protocol} ACME 元数据缺失: {tag}")
    inbound["tls"] = acme_tls(next_domain, next_email, secret, data_directory)


def delete_protocol(config: dict, protocol: str, tag: str) -> None:
    inbounds = config["inbounds"]
    matches = [item for item in inbounds if item.get("tag") == tag]
    if len(matches) != 1 or not is_protocol(matches[0], protocol):
        raise ValueError(f"未知 {protocol} 协议: {tag}")
    config["inbounds"] = [item for item in inbounds if item.get("tag") != tag]


def main() -> None:
    (
        operation,
        protocol,
        config_file,
        meta_file,
        users_file,
        acme_secret_file,
        acme_data_dir,
        tag,
        port_text,
        domain,
        email,
    ) = sys.argv[1:]
    if protocol not in PROTOCOL_TYPES:
        raise ValueError(f"不支持的 TLS 协议: {protocol}")
    config = load_object(config_file)
    meta = load_object(meta_file)
    users_payload = load_object(users_file)
    secret = load_acme_secret(acme_secret_file) if operation in {"add", "update"} else {}
    inbounds = config.setdefault("inbounds", [])
    if not isinstance(inbounds, list):
        raise ValueError("config.inbounds 不是数组")
    data_directory = str(Path(acme_data_dir) / tag)

    if operation == "add":
        add_protocol(
            config,
            users_payload,
            protocol,
            tag,
            int(port_text),
            domain,
            email,
            secret,
            data_directory,
        )
    elif operation == "update":
        update_protocol(
            config,
            protocol,
            tag,
            port_text,
            domain,
            email,
            secret,
            data_directory,
        )
    elif operation == "delete":
        delete_protocol(config, protocol, tag)
    else:
        raise ValueError(f"未知协议操作: {operation}")

    config["inbounds"] = sorted(config["inbounds"], key=lambda item: str(item.get("tag", "")))
    Path(config_file).write_text(
        json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    Path(meta_file).write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
SUBFLOW_TLS_PROTOCOL_MUTATOR_PY
}

# --- 00_base.sh ---
umask 077

SUBFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${SUBFLOW_CONFIG_PATH:=/etc/sing-box/config.json}"
: "${SUBFLOW_USERS_PATH:=/etc/sing-box-manager/users.json}"
: "${SUBFLOW_META_PATH:=/etc/sing-box-manager/meta.json}"
: "${SUBFLOW_SUBSCRIPTION_INDEX_PATH:=/etc/sing-box-manager/subscriptions.json}"
: "${SUBFLOW_STATE_DIR:=/etc/sing-box-manager}"
: "${SUBFLOW_SECRETS_DIR:=/etc/sing-box-manager/secrets}"
: "${SUBFLOW_LOCK_PATH:=/var/lock/subflow-singbox.lock}"
: "${SUBFLOW_SINGBOX_BIN:=/usr/local/bin/sing-box}"
: "${SUBFLOW_SERVICE_NAME:=sing-box}"
: "${SUBFLOW_VERSION_STAMP:=${SUBFLOW_STATE_DIR}/.installed-release}"
: "${SUBFLOW_BINARY_STORE_DIR:=/var/lib/subflow-singbox/versions}"
: "${SUBFLOW_MANAGER_TARGET:=/root/sb.sh}"
: "${SUBFLOW_SHORTCUT_PATH:=/usr/local/bin/s}"
: "${SUBFLOW_SYSTEMD_UNIT_PATH:=/etc/systemd/system/${SUBFLOW_SERVICE_NAME}.service}"
: "${SUBFLOW_OPENRC_SERVICE_PATH:=/etc/init.d/${SUBFLOW_SERVICE_NAME}}"
: "${SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH:=${SUBFLOW_SECRETS_DIR}/cloudflare-acme.json}"
: "${SUBFLOW_ACME_DATA_DIR:=${SUBFLOW_SECRETS_DIR}/acme}"

subflow_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

subflow_has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

subflow_require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! subflow_has_cmd "$cmd"; then
      subflow_fail "缺少必要命令: ${cmd}"
      return 1
    fi
  done
}

subflow_is_valid_username() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

subflow_owner_from_name() {
  local name="$1"
  if [[ "$name" == *"@"* ]]; then
    printf '%s\n' "${name#*@}"
  else
    printf '%s\n' "admin"
  fi
}

subflow_username_from_name() {
  subflow_owner_from_name "$1"
}

subflow_json_is_object() {
  local file="$1"
  subflow_has_cmd jq || return 1
  jq -e 'type == "object"' "$file" >/dev/null 2>&1
}

subflow_json_is_array() {
  local file="$1"
  subflow_has_cmd jq || return 1
  jq -e 'type == "array"' "$file" >/dev/null 2>&1
}

subflow_json_validate() {
  local file="$1"
  if ! subflow_has_cmd jq; then
    subflow_fail "缺少必要命令: jq"
    return 1
  fi
  jq -e . "$file" >/dev/null
}

subflow_file_write_atomic() {
  local target="$1"
  local content_file="$2"
  local mode="$3"
  local target_dir tmp_file
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir" || return 1
  tmp_file="$(mktemp "${target_dir}/.${RANDOM:-0}.XXXXXX")" || return 1
  if ! cp "$content_file" "$tmp_file" || ! chmod "$mode" "$tmp_file" || ! mv -f "$tmp_file" "$target"; then
    rm -f "$tmp_file"
    return 1
  fi
}

subflow_json_write_atomic() {
  subflow_file_write_atomic "$1" "$2" 600
}

subflow_service_unit_path() {
  case "${SUBFLOW_INIT:-$(subflow_detect_init)}" in
    systemd)
      printf '%s\n' "$SUBFLOW_SYSTEMD_UNIT_PATH"
      ;;
    openrc)
      printf '%s\n' "$SUBFLOW_OPENRC_SERVICE_PATH"
      ;;
  esac
}

subflow_binary_exists() {
  [[ -x "$SUBFLOW_SINGBOX_BIN" ]]
}

subflow_key_file_state() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf '存在'
  else
    printf '缺失'
  fi
}

subflow_json_dir_ready() {
  mkdir -p "$SUBFLOW_STATE_DIR" "$SUBFLOW_SECRETS_DIR"
}

# --- 05_releases.sh ---
subflow_release_normalize_version() {
  local version="${1#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    subflow_fail "版本号不合法: ${1}"
    return 1
  fi
  printf '%s\n' "$version"
}

subflow_release_manifest_validate() {
  if ! subflow_release_manifest | jq -e '
    .latest as $latest
    | type == "object"
    and .schema_version == 1
    and (.repository | type == "string")
    and (.latest | type == "string")
    and (.releases | type == "object")
    and (.releases[$latest] | type == "object")
  ' >/dev/null; then
    subflow_fail "sing-box 批准清单无效"
    return 1
  fi
}

subflow_release_latest() {
  local version
  subflow_release_manifest_validate || return 1
  version="$(subflow_release_manifest | jq -er '.latest')" || return 1
  subflow_release_normalize_version "$version"
}

subflow_release_repository() {
  local repository
  subflow_release_manifest_validate || return 1
  repository="$(subflow_release_manifest | jq -er '.repository')" || return 1
  if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    subflow_fail "批准清单中的仓库名不合法"
    return 1
  fi
  printf '%s\n' "$repository"
}

subflow_release_asset_field() {
  local version arch field value
  version="$(subflow_release_normalize_version "$1")" || return 1
  arch="$2"
  field="$3"
  case "$arch" in
    amd64|arm64) ;;
    *)
      subflow_fail "不支持的发布架构: ${arch}"
      return 1
      ;;
  esac
  case "$field" in
    name|sha256) ;;
    *) return 1 ;;
  esac

  subflow_release_manifest_validate || return 1
  value="$(subflow_release_manifest | jq -er \
    --arg version "$version" \
    --arg arch "$arch" \
    --arg field "$field" \
    '.releases[$version].assets[$arch][$field] // empty')" || {
      subflow_fail "版本未获批准: ${version}/${arch}"
      return 1
    }

  if [[ "$field" == "name" && ! "$value" =~ ^sing-box-linux-(amd64|arm64)$ ]]; then
    subflow_fail "批准清单中的资产名不合法"
    return 1
  fi
  if [[ "$field" == "sha256" && ! "$value" =~ ^[0-9a-f]{64}$ ]]; then
    subflow_fail "批准清单中的 SHA256 不合法"
    return 1
  fi
  printf '%s\n' "$value"
}

subflow_release_asset_name() {
  subflow_release_asset_field "$1" "$2" name
}

subflow_release_sha256() {
  subflow_release_asset_field "$1" "$2" sha256
}

subflow_release_url() {
  local version="$1" arch="$2" repository asset base_url
  version="$(subflow_release_normalize_version "$version")" || return 1
  repository="$(subflow_release_repository)" || return 1
  asset="$(subflow_release_asset_name "$version" "$arch")" || return 1
  base_url="${SUBFLOW_RELEASE_BASE_URL:-https://github.com/${repository}/releases/download}"
  printf '%s/v%s/%s\n' "${base_url%/}" "$version" "$asset"
}
# --- 10_platform.sh ---
subflow_detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      printf '%s\n' "amd64"
      ;;
    aarch64|arm64)
      printf '%s\n' "arm64"
      ;;
    *)
      subflow_fail "不支持的平台架构: ${machine}"
      return 1
      ;;
  esac
}

subflow_detect_init() {
  if subflow_has_cmd systemctl && [[ -d /run/systemd/system || -n "${INVOCATION_ID:-}" ]]; then
    printf '%s\n' "systemd"
    return 0
  fi
  if subflow_has_cmd rc-service || [[ -d /run/openrc ]]; then
    printf '%s\n' "openrc"
    return 0
  fi
  subflow_fail "不支持的 init 系统"
  return 1
}

subflow_detect_pkg_manager() {
  local candidate
  for candidate in apt-get dnf yum pacman apk zypper; do
    if subflow_has_cmd "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  subflow_fail "不支持的软件包管理器"
  return 1
}

subflow_detect_platform() {
  local pkg init arch
  pkg="$(subflow_detect_pkg_manager)" || return 1
  init="$(subflow_detect_init)" || return 1
  arch="$(subflow_detect_arch)" || return 1
  printf '%s|%s|%s\n' "$pkg" "$init" "$arch"
}

# --- 20_paths.sh ---
subflow_key_paths() {
  printf '%s\n' "$SUBFLOW_CONFIG_PATH"
  printf '%s\n' "$SUBFLOW_USERS_PATH"
  printf '%s\n' "$SUBFLOW_META_PATH"
  printf '%s\n' "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"
}

subflow_state_paths() {
  printf '%s\n' "$SUBFLOW_STATE_DIR"
  printf '%s\n' "$SUBFLOW_SECRETS_DIR"
  printf '%s\n' "$SUBFLOW_LOCK_PATH"
}

subflow_service_paths() {
  subflow_service_unit_path
}

# --- 30_lock.sh ---
subflow_lock_acquire() {
  if ! subflow_has_cmd flock; then
    subflow_fail "缺少必要命令: flock"
    return 1
  fi
  if ! mkdir -p "$(dirname "$SUBFLOW_LOCK_PATH")"; then
    subflow_fail "无法创建锁目录"
    return 1
  fi
  if ! exec {SUBFLOW_LOCK_FD}>"$SUBFLOW_LOCK_PATH"; then
    subflow_fail "无法创建锁文件"
    return 1
  fi
  if ! flock -n "$SUBFLOW_LOCK_FD"; then
    subflow_lock_release
    subflow_fail "已有另一个实例持有全局锁"
    return 1
  fi
}

subflow_lock_release() {
  if [[ -n "${SUBFLOW_LOCK_FD:-}" ]]; then
    flock -u "$SUBFLOW_LOCK_FD" >/dev/null 2>&1 || true
    { exec {SUBFLOW_LOCK_FD}>&-; } 2>/dev/null || true
    unset SUBFLOW_LOCK_FD
  fi
}

subflow_txn_dir_create() {
  mkdir -p "$SUBFLOW_STATE_DIR"
  mktemp -d "${SUBFLOW_STATE_DIR}/.txn.XXXXXX"
}

subflow_txn_dir_is_managed() {
  local txn_dir="$1" state_dir parent_dir base_name
  [[ -d "$SUBFLOW_STATE_DIR" ]] || return 1
  [[ -d "$txn_dir" ]] || return 1
  [[ ! -L "$txn_dir" ]] || return 1
  state_dir="$(cd "$SUBFLOW_STATE_DIR" && pwd -P)" || return 1
  parent_dir="$(cd "$(dirname "$txn_dir")" && pwd -P)" || return 1
  base_name="$(basename "$txn_dir")"
  [[ "$parent_dir" == "$state_dir" && "$base_name" =~ ^\.txn\.[A-Za-z0-9]+$ ]]
}

subflow_txn_require_managed() {
  local txn_dir="$1"
  if ! subflow_txn_dir_is_managed "$txn_dir"; then
    subflow_fail "非法事务目录: ${txn_dir}"
    return 1
  fi
}

subflow_txn_begin() {
  local txn_dir="$1"
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  : >"${txn_dir}/recovery.pending"
}

subflow_txn_commit() {
  local txn_dir="$1"
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  rm -f "${txn_dir}/recovery.pending"
}

subflow_txn_abort() {
  local txn_dir="$1"
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  rm -rf "$txn_dir"
}

subflow_txn_has_pending() {
  local pending
  for pending in "${SUBFLOW_STATE_DIR}"/.txn.*/recovery.pending; do
    [[ -e "$pending" ]] && return 0
  done
  return 1
}

subflow_txn_cleanup_stale() {
  local txn_dir pending_found=0
  for txn_dir in "${SUBFLOW_STATE_DIR}"/.txn.*; do
    [[ -d "$txn_dir" ]] || continue
    if [[ -e "${txn_dir}/recovery.pending" ]]; then
      pending_found=1
      continue
    fi
    if ! subflow_txn_abort "$txn_dir"; then
      return 1
    fi
  done
  if (( pending_found != 0 )); then
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
  fi
}

# --- 40_json.sh ---
subflow_json_require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    subflow_fail "缺少文件: ${file}"
    return 1
  fi
}

subflow_json_require_object() {
  local file="$1"
  if ! subflow_json_require_file "$file" || ! subflow_json_validate "$file"; then
    return 1
  fi
  if ! jq -e 'type == "object"' "$file" >/dev/null; then
    subflow_fail "JSON 不是对象: ${file}"
    return 1
  fi
}

subflow_json_require_array() {
  local file="$1"
  if ! subflow_json_require_file "$file" || ! subflow_json_validate "$file"; then
    return 1
  fi
  if ! jq -e 'type == "array"' "$file" >/dev/null; then
    subflow_fail "JSON 不是数组: ${file}"
    return 1
  fi
}

subflow_json_require_schema_v1() {
  local file="$1"
  if ! jq -e 'type == "object" and .schema_version == 1 and (.users | type == "object")' "$file" >/dev/null; then
    subflow_fail "schema_version 不兼容: ${file}"
    return 1
  fi
}

subflow_json_write_string() {
  local target="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp "$(dirname "$target")/.value.XXXXXX")"
  printf '%s\n' "$value" >"$tmp_file"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$target"
}

# --- 50_status.sh ---
subflow_service_file_exists() {
  local candidate
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] && return 0
  done < <(subflow_service_paths)
  return 1
}

cmd_status() {
  local platform_info pkg init arch service_state
  platform_info="$(subflow_detect_platform)" || return 1
  pkg="${platform_info%%|*}"
  init="${platform_info#*|}"
  init="${init%%|*}"
  arch="${platform_info##*|}"
  service_state="未找到"
  if subflow_service_file_exists; then
    service_state="已安装"
  fi

  banner
  step "状态"
  info "平台: 包管理器=${pkg} · init=${init} · 架构=${arch}"
  info "sing-box 二进制: ${SUBFLOW_SINGBOX_BIN} · $(subflow_key_file_state "$SUBFLOW_SINGBOX_BIN")"
  info "服务文件: ${service_state}"
  info "配置: $(subflow_key_file_state "$SUBFLOW_CONFIG_PATH")"
  info "用户库: $(subflow_key_file_state "$SUBFLOW_USERS_PATH")"
  info "元数据: $(subflow_key_file_state "$SUBFLOW_META_PATH")"
  info "订阅索引: $(subflow_key_file_state "$SUBFLOW_SUBSCRIPTION_INDEX_PATH")"
  info "密钥目录: $(subflow_key_file_state "$SUBFLOW_SECRETS_DIR")"
}

# --- 60_doctor.sh ---
subflow_doctor_version_has_tags() {
  local version_output="$1"
  local tag
  for tag in with_v2ray_api with_wireguard with_acme; do
    if [[ "$version_output" != *"$tag"* ]]; then
      subflow_fail "sing-box 版本输出缺少构建标签: ${tag}"
      return 1
    fi
  done
}

subflow_doctor_check_permissions() {
  local path expected mode
  for path in "$SUBFLOW_CONFIG_PATH" "$SUBFLOW_USERS_PATH" "$SUBFLOW_META_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"; do
    if [[ -e "$path" ]]; then
      expected="600"
      if [[ -d "$path" ]]; then
        expected="700"
      fi
      mode="$(stat -c '%a' "$path")"
      [[ "$mode" == "$expected" ]] || return 1
    fi
  done

  if [[ -d "$SUBFLOW_SECRETS_DIR" ]]; then
    mode="$(stat -c '%a' "$SUBFLOW_SECRETS_DIR")"
    [[ "$mode" == "700" ]] || return 1
  fi
}

cmd_doctor() {
  local failures=0
  local version_output config_ok index_ok

  if ! subflow_require_cmd jq openssl tar sha256sum flock python3; then
    failures=$((failures + 1))
  fi
  subflow_binary_exists || { err "sing-box 二进制缺失"; failures=$((failures + 1)); }
  [[ -d "$SUBFLOW_STATE_DIR" ]] || { err "状态目录缺失"; failures=$((failures + 1)); }
  [[ -d "$SUBFLOW_SECRETS_DIR" ]] || { err "密钥目录缺失"; failures=$((failures + 1)); }
  subflow_doctor_check_permissions || { err "目录或文件权限不符合要求"; failures=$((failures + 1)); }

  if subflow_binary_exists; then
    version_output="$("$SUBFLOW_SINGBOX_BIN" version 2>&1)" || { err "无法读取 sing-box 版本"; failures=$((failures + 1)); version_output=""; }
    if [[ -n "$version_output" ]]; then
      subflow_doctor_version_has_tags "$version_output" || failures=$((failures + 1))
    fi
  fi

  if [[ -f "$SUBFLOW_CONFIG_PATH" ]]; then
    subflow_json_require_object "$SUBFLOW_CONFIG_PATH" || failures=$((failures + 1))
    if subflow_binary_exists; then
      if ! "$SUBFLOW_SINGBOX_BIN" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null 2>&1; then
        err "sing-box check 失败"
        failures=$((failures + 1))
      fi
    fi
  else
    err "配置文件缺失"
    failures=$((failures + 1))
  fi

  if [[ -f "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]]; then
    if subflow_json_require_object "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" && subflow_json_require_schema_v1 "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"; then
      index_ok=1
    else
      err "订阅索引不通过 schema 检查"
      failures=$((failures + 1))
    fi
  else
    err "订阅索引缺失"
    failures=$((failures + 1))
  fi

  if (( failures == 0 )); then
    ok "doctor 通过"
    return 0
  fi

  err "doctor 失败: ${failures} 项检查未通过"
  return 1
}

# --- 70_check.sh ---
subflow_check_users_file() {
  local file="$1"
  if ! jq -e 'type == "object" and .schema_version == 1 and (.users | type == "object")' "$file" >/dev/null; then
    subflow_fail "用户库结构错误: ${file}"
    return 1
  fi
}

subflow_check_meta_file() {
  local file="$1"
  if ! jq -e 'type == "object"' "$file" >/dev/null; then
    subflow_fail "元数据结构错误: ${file}"
    return 1
  fi
}

subflow_check_config_file() {
  local file="$1"
  if ! jq -e 'type == "object" and (.inbounds | type == "array")' "$file" >/dev/null; then
    subflow_fail "配置结构错误: ${file}"
    return 1
  fi
}

subflow_check_subscription_index_file() {
  local file="$1"
  if ! jq -e 'type == "object" and .schema_version == 1 and (.users | type == "object")' "$file" >/dev/null; then
    subflow_fail "订阅索引结构错误: ${file}"
    return 1
  fi
}

cmd_check() {
  subflow_require_cmd jq || return 1
  subflow_json_require_file "$SUBFLOW_CONFIG_PATH" || return 1
  subflow_json_require_file "$SUBFLOW_USERS_PATH" || return 1
  subflow_json_require_file "$SUBFLOW_META_PATH" || return 1
  subflow_json_require_file "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1

  subflow_json_validate "$SUBFLOW_CONFIG_PATH" || return 1
  subflow_json_validate "$SUBFLOW_USERS_PATH" || return 1
  subflow_json_validate "$SUBFLOW_META_PATH" || return 1
  subflow_json_validate "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1

  subflow_check_config_file "$SUBFLOW_CONFIG_PATH" || return 1
  subflow_check_users_file "$SUBFLOW_USERS_PATH" || return 1
  subflow_check_meta_file "$SUBFLOW_META_PATH" || return 1
  subflow_check_subscription_index_file "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1

  if subflow_binary_exists; then
    "$SUBFLOW_SINGBOX_BIN" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null
  else
    subflow_fail "缺少 sing-box 二进制"
    return 1
  fi
}

cmd_periodic_sync() {
  cmd_rebuild
}

cmd_daily_maintenance() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if ! subflow_txn_cleanup_stale; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "daily-maintenance 完成"
}

cmd_tg_agent_sync() {
  return 0
}

# --- 75_service.sh ---
subflow_service_validate_exec_paths() {
  if [[ "$SUBFLOW_SINGBOX_BIN" =~ [[:space:]] || "$SUBFLOW_CONFIG_PATH" =~ [[:space:]] ]]; then
    subflow_fail "服务路径不能包含空白字符"
    return 1
  fi
}

subflow_service_target() {
  local init="$1"
  case "$init" in
    systemd) printf '%s\n' "$SUBFLOW_SYSTEMD_UNIT_PATH" ;;
    openrc) printf '%s\n' "$SUBFLOW_OPENRC_SERVICE_PATH" ;;
    *)
      subflow_fail "不支持的 init 系统: ${init}"
      return 1
      ;;
  esac
}

subflow_service_is_active() {
  local init="$1"
  case "$init" in
    systemd) systemctl is-active --quiet "$SUBFLOW_SERVICE_NAME" ;;
    openrc) rc-service "$SUBFLOW_SERVICE_NAME" status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

subflow_service_write_definition() {
  local init="$1" target source_file
  subflow_service_validate_exec_paths || return 1
  target="$(subflow_service_target "$init")" || return 1
  source_file="$(mktemp)" || return 1

  case "$init" in
    systemd)
      cat >"$source_file" <<EOF
[Unit]
Description=sing-box service managed by subflow
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SUBFLOW_SINGBOX_BIN} run -c ${SUBFLOW_CONFIG_PATH}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      if ! subflow_file_write_atomic "$target" "$source_file" 644; then
        rm -f "$source_file"
        return 1
      fi
      ;;
    openrc)
      cat >"$source_file" <<EOF
#!/sbin/openrc-run
description="sing-box service managed by subflow"
command="${SUBFLOW_SINGBOX_BIN}"
command_args="run -c ${SUBFLOW_CONFIG_PATH}"
command_background="yes"
pidfile="/run/${SUBFLOW_SERVICE_NAME}.pid"

depend() {
  need net
  after firewall
}
EOF
      if ! subflow_file_write_atomic "$target" "$source_file" 755; then
        rm -f "$source_file"
        return 1
      fi
      ;;
  esac
  rm -f "$source_file"
}

subflow_service_enable_and_restart() {
  local init="$1"
  case "$init" in
    systemd)
      systemctl daemon-reload || return 1
      systemctl enable "$SUBFLOW_SERVICE_NAME" >/dev/null || return 1
      if subflow_service_is_active "$init"; then
        systemctl restart "$SUBFLOW_SERVICE_NAME" || return 1
      else
        systemctl start "$SUBFLOW_SERVICE_NAME" || return 1
      fi
      ;;
    openrc)
      rc-update add "$SUBFLOW_SERVICE_NAME" default >/dev/null || return 1
      if subflow_service_is_active "$init"; then
        rc-service "$SUBFLOW_SERVICE_NAME" restart || return 1
      else
        rc-service "$SUBFLOW_SERVICE_NAME" start || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  subflow_service_is_active "$init"
}

subflow_service_apply_config_transaction() {
  local init="$1" was_active="$2"
  case "$init" in
    systemd)
      systemctl daemon-reload || return 1
      if [[ "$was_active" == "true" ]]; then
        systemctl restart "$SUBFLOW_SERVICE_NAME" || return 1
      else
        systemctl start "$SUBFLOW_SERVICE_NAME" || return 1
      fi
      ;;
    openrc)
      if [[ "$was_active" == "true" ]]; then
        rc-service "$SUBFLOW_SERVICE_NAME" restart || return 1
      else
        rc-service "$SUBFLOW_SERVICE_NAME" start || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  subflow_service_is_active "$init" || return 1
  if [[ "$was_active" != "true" ]]; then
    case "$init" in
      systemd) systemctl stop "$SUBFLOW_SERVICE_NAME" || return 1 ;;
      openrc) rc-service "$SUBFLOW_SERVICE_NAME" stop || return 1 ;;
    esac
  fi
}

subflow_service_reload_after_restore() {
  local init="$1" was_active="$2" service_existed="$3"
  case "$init" in
    systemd)
      if [[ "$was_active" != "true" ]]; then
        systemctl stop "$SUBFLOW_SERVICE_NAME" >/dev/null 2>&1 || true
      fi
      systemctl daemon-reload || return 1
      if [[ "$service_existed" != "true" ]]; then
        systemctl disable "$SUBFLOW_SERVICE_NAME" >/dev/null 2>&1 || true
      fi
      ;;
    openrc)
      if [[ "$was_active" != "true" ]]; then
        rc-service "$SUBFLOW_SERVICE_NAME" stop >/dev/null 2>&1 || true
      fi
      if [[ "$service_existed" != "true" ]]; then
        rc-update del "$SUBFLOW_SERVICE_NAME" default >/dev/null 2>&1 || true
      fi
      ;;
    *) return 1 ;;
  esac
  if [[ "$was_active" == "true" ]]; then
    case "$init" in
      systemd) systemctl restart "$SUBFLOW_SERVICE_NAME" ;;
      openrc) rc-service "$SUBFLOW_SERVICE_NAME" restart ;;
    esac
  fi
}
# --- 80_acme.sh ---
subflow_acme_secret_tool() {
  subflow_acme_secret_source | python3 - "$@"
}

subflow_acme_cloudflare_validate() {
  subflow_acme_secret_tool validate "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH"
}

subflow_acme_cloudflare_field() {
  subflow_acme_secret_tool field "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$1"
}

subflow_acme_config_state() {
  subflow_acme_secret_tool config-state "$SUBFLOW_CONFIG_PATH"
}

subflow_acme_rotation_manifest_path() {
  printf '%s\n' "$1/acme-rotation.manifest.json"
}

subflow_acme_rotation_manifest_field() {
  local txn_dir="$1" field="$2"
  subflow_acme_secret_tool rotation-manifest-field \
    "$(subflow_acme_rotation_manifest_path "$txn_dir")" "$field"
}

subflow_acme_rotation_write_manifest() {
  local txn_dir="$1" init="$2" service_target="$3"
  local secret_existed="$4" service_was_active="$5" manifest_file
  manifest_file="$(subflow_acme_rotation_manifest_path "$txn_dir")"
  if ! subflow_acme_secret_tool rotation-manifest-write \
    "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" "$SUBFLOW_CONFIG_PATH" \
    "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$service_target" "$init" \
    "$secret_existed" "$service_was_active"; then
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_acme_rotation_manifest_is_valid() {
  local txn_dir="$1" manifest_file init expected_service_target
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_acme_rotation_manifest_path "$txn_dir")"
  if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
    subflow_fail "缺少可信 ACME 轮换清单"
    return 1
  fi
  init="$(subflow_acme_rotation_manifest_field "$txn_dir" init)" || return 1
  expected_service_target="$(subflow_service_target "$init")" || return 1
  if ! subflow_acme_secret_tool rotation-manifest-validate \
    "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" "$SUBFLOW_CONFIG_PATH" \
    "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$expected_service_target"; then
    subflow_fail "非法 ACME 轮换清单: ${manifest_file}"
    return 1
  fi
}

subflow_acme_rotation_restore_from_manifest() {
  local txn_dir="$1" backup_dir init secret_existed service_was_active
  local config_backup secret_backup
  if ! subflow_acme_rotation_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  backup_dir="$txn_dir/backup"
  config_backup="$backup_dir/config.json"
  secret_backup="$backup_dir/cloudflare-acme.json"
  init="$(subflow_acme_rotation_manifest_field "$txn_dir" init)" || return 1
  secret_existed="$(subflow_acme_rotation_manifest_field "$txn_dir" secret_existed)" || return 1
  service_was_active="$(subflow_acme_rotation_manifest_field "$txn_dir" service_was_active)" || return 1
  if [[ ! -f "$config_backup" || -L "$config_backup" ]]; then
    subflow_fail "缺少可信 ACME 配置备份: ${config_backup}"
    return 1
  fi
  if [[ "$secret_existed" == "true" && ( ! -f "$secret_backup" || -L "$secret_backup" ) ]]; then
    subflow_fail "缺少可信 ACME 凭据备份: ${secret_backup}"
    return 1
  fi
  subflow_file_write_atomic "$SUBFLOW_CONFIG_PATH" "$config_backup" 600 || return 1
  if [[ "$secret_existed" == "true" ]]; then
    subflow_file_write_atomic "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$secret_backup" 600 || return 1
  else
    rm -f "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" || return 1
  fi
  subflow_service_reload_after_restore "$init" "$service_was_active" true
}

subflow_acme_rotation_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_acme_rotation_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧凭据和配置"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_acme_cloudflare_rotate() {
  local txn_dir="$1" candidate_secret="$2"
  local candidate_config backup_dir init service_target
  local secret_existed=false service_was_active=false
  candidate_config="$txn_dir/config.json"
  backup_dir="$txn_dir/backup"
  if ! subflow_require_cmd python3 || ! subflow_binary_exists; then
    if ! subflow_binary_exists; then subflow_fail "缺少 sing-box 二进制"; fi
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  service_target="$(subflow_service_target "$init")" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  if [[ ! -f "$service_target" ]]; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "sing-box 服务定义缺失: ${service_target}"
    return 1
  fi
  if subflow_service_is_active "$init"; then service_was_active=true; fi
  if [[ -L "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" ]]; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "Cloudflare ACME 凭据路径不能是符号链接"
    return 1
  fi
  [[ -f "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" ]] && secret_existed=true

  if ! subflow_acme_secret_tool rewrite-config \
    "$SUBFLOW_CONFIG_PATH" "$candidate_secret" "$candidate_config" \
    || ! subflow_json_require_object "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "候选 ACME 配置校验失败，未写入现有状态"
    return 1
  fi
  if ! mkdir -p "$backup_dir" \
    || ! cp "$SUBFLOW_CONFIG_PATH" "$backup_dir/config.json" \
    || { [[ "$secret_existed" == "true" ]] \
      && ! cp "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$backup_dir/cloudflare-acme.json"; }; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  chmod 600 "$backup_dir"/* 2>/dev/null || true
  if ! subflow_acme_rotation_write_manifest \
    "$txn_dir" "$init" "$service_target" "$secret_existed" "$service_was_active" \
    || ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  if ! subflow_file_write_atomic "$SUBFLOW_CONFIG_PATH" "$candidate_config" 600 \
    || ! subflow_file_write_atomic "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$candidate_secret" 600; then
    subflow_acme_rotation_rollback "$txn_dir" "ACME 轮换文件写入失败"
    return 1
  fi
  if ! subflow_service_apply_config_transaction "$init" "$service_was_active"; then
    subflow_acme_rotation_rollback "$txn_dir" "ACME 轮换服务应用失败"
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "Cloudflare ACME 凭据已在线轮换"
}

subflow_acme_cloudflare_import() {
  local api_token_file="$1" zone_token_file="${2:--}" txn_dir candidate config_state
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd python3; then
    subflow_lock_release
    return 1
  fi
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate="$txn_dir/cloudflare-acme.json"
  if ! mkdir -p "$SUBFLOW_SECRETS_DIR" "$SUBFLOW_ACME_DATA_DIR" \
    || ! subflow_acme_secret_tool create "$api_token_file" "$zone_token_file" "$candidate"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  chmod 700 "$SUBFLOW_SECRETS_DIR" "$SUBFLOW_ACME_DATA_DIR" 2>/dev/null || true
  config_state="$(subflow_acme_config_state)" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  if [[ "$config_state" == "used" ]]; then
    subflow_acme_cloudflare_rotate "$txn_dir" "$candidate"
    return $?
  fi
  if ! subflow_file_write_atomic "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$candidate" 600; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  subflow_txn_abort "$txn_dir" || true
  subflow_lock_release
  ok "Cloudflare ACME 凭据已导入"
}

subflow_acme_status() {
  if subflow_acme_cloudflare_validate >/dev/null 2>&1; then
    info "Cloudflare DNS-01: 已配置"
  else
    info "Cloudflare DNS-01: 未配置"
  fi
}

subflow_acme_clear() {
  local confirmation="$1"
  [[ "$confirmation" == "YES" ]] || {
    subflow_fail "清除 ACME 凭据必须输入 YES"
    return 1
  }
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  local config_state
  config_state="$(subflow_acme_config_state)" || {
    subflow_lock_release
    return 1
  }
  if [[ "$config_state" == "used" ]]; then
    subflow_lock_release
    subflow_fail "请先删除使用 Cloudflare ACME 的 TLS 协议"
    return 1
  fi
  if ! rm -f "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "Cloudflare ACME 凭据已清除"
}

cmd_acme_dispatch() {
  local subcmd="${1:-status}"
  shift || true
  case "$subcmd" in
    status)
      [[ "$#" -eq 0 ]] || { subflow_fail "acme status 不接受参数"; return 1; }
      subflow_acme_status
      ;;
    import-cloudflare)
      [[ "$#" -ge 1 && "$#" -le 2 ]] \
        || { subflow_fail "用法: acme import-cloudflare <api-token-file> [zone-token-file]"; return 1; }
      subflow_acme_cloudflare_import "$@"
      ;;
    clear)
      [[ "$#" -eq 1 ]] || { subflow_fail "用法: acme clear YES"; return 1; }
      subflow_acme_clear "$1"
      ;;
    *)
      subflow_fail "未知 acme 子命令: ${subcmd}"
      return 1
      ;;
  esac
}
# --- 80_install.sh ---
subflow_require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    subflow_fail "安装或更新 sing-box 需要 root 权限"
    return 1
  fi
}

subflow_binary_version() {
  local binary="$1" output first_line
  output="$("$binary" version 2>&1)" || return 1
  first_line="${output%%$'\n'*}"
  if [[ ! "$first_line" =~ ^sing-box[[:space:]]+(version[[:space:]]+)?v?([0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?) ]]; then
    return 1
  fi
  printf '%s\n' "${BASH_REMATCH[2]}"
}

subflow_install_verify_candidate() {
  local candidate="$1" version="$2" expected_sha256="$3"
  local actual_version version_output tag

  if ! printf '%s  %s\n' "$expected_sha256" "$candidate" | sha256sum -c - >/dev/null 2>&1; then
    subflow_fail "sing-box 下载文件 SHA256 不匹配"
    return 1
  fi
  chmod 755 "$candidate" || return 1
  actual_version="$(subflow_binary_version "$candidate")" || {
    subflow_fail "无法读取候选 sing-box 版本"
    return 1
  }
  if [[ "$actual_version" != "$version" ]]; then
    subflow_fail "候选版本不匹配: 期望 ${version}，实际 ${actual_version}"
    return 1
  fi
  version_output="$("$candidate" version 2>&1)" || return 1
  for tag in with_v2ray_api with_wireguard with_acme; do
    if [[ "$version_output" != *"$tag"* ]]; then
      subflow_fail "候选 sing-box 缺少构建标签: ${tag}"
      return 1
    fi
  done
  if [[ -f "$SUBFLOW_CONFIG_PATH" ]] && ! "$candidate" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null 2>&1; then
    subflow_fail "候选 sing-box 无法通过现有配置检查"
    return 1
  fi
}

subflow_install_manifest_path() {
  printf '%s\n' "$1/install.manifest.json"
}

subflow_install_write_manifest() {
  local txn_dir="$1" init="$2" binary_existed="$3" stamp_existed="$4"
  local service_changed="$5" service_existed="$6" service_was_active="$7"
  local manifest_file service_target
  manifest_file="$(subflow_install_manifest_path "$txn_dir")"
  service_target="$(subflow_service_target "$init")" || return 1

  if ! jq -n \
    --arg txn_dir "$txn_dir" \
    --arg state_dir "$SUBFLOW_STATE_DIR" \
    --arg binary_target "$SUBFLOW_SINGBOX_BIN" \
    --arg stamp_target "$SUBFLOW_VERSION_STAMP" \
    --arg service_target "$service_target" \
    --arg init "$init" \
    --argjson binary_existed "$binary_existed" \
    --argjson stamp_existed "$stamp_existed" \
    --argjson service_changed "$service_changed" \
    --argjson service_existed "$service_existed" \
    --argjson service_was_active "$service_was_active" \
    '{
      version: 1,
      kind: "sing-box-install",
      txn_dir: $txn_dir,
      state_dir: $state_dir,
      binary_target: $binary_target,
      stamp_target: $stamp_target,
      service_target: $service_target,
      init: $init,
      binary_backup: "backup/sing-box",
      stamp_backup: "backup/installed-release",
      service_backup: "backup/service",
      binary_existed: $binary_existed,
      stamp_existed: $stamp_existed,
      service_changed: $service_changed,
      service_existed: $service_existed,
      service_was_active: $service_was_active
    }' >"$manifest_file"; then
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_install_manifest_is_valid() {
  local txn_dir="$1" manifest_file init service_target expected_service_target
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_install_manifest_path "$txn_dir")"
  subflow_json_require_object "$manifest_file" || return 1
  init="$(jq -er '.init' "$manifest_file")" || return 1
  service_target="$(jq -er '.service_target' "$manifest_file")" || return 1
  expected_service_target="$(subflow_service_target "$init")" || return 1
  if [[ "$service_target" != "$expected_service_target" ]]; then
    subflow_fail "安装恢复清单中的服务路径不合法"
    return 1
  fi
  if ! jq -e \
    --arg txn_dir "$txn_dir" \
    --arg state_dir "$SUBFLOW_STATE_DIR" \
    --arg binary_target "$SUBFLOW_SINGBOX_BIN" \
    --arg stamp_target "$SUBFLOW_VERSION_STAMP" \
    'type == "object"
     and .version == 1
     and .kind == "sing-box-install"
     and .txn_dir == $txn_dir
     and .state_dir == $state_dir
     and .binary_target == $binary_target
     and .stamp_target == $stamp_target
     and (.init == "systemd" or .init == "openrc")
     and .binary_backup == "backup/sing-box"
     and .stamp_backup == "backup/installed-release"
     and .service_backup == "backup/service"
     and (.binary_existed | type == "boolean")
     and (.stamp_existed | type == "boolean")
     and (.service_changed | type == "boolean")
     and (.service_existed | type == "boolean")
     and (.service_was_active | type == "boolean")' "$manifest_file" >/dev/null; then
    subflow_fail "非法安装恢复清单: ${manifest_file}"
    return 1
  fi
}

subflow_install_restore_file() {
  local existed="$1" backup_file="$2" target_file="$3" mode="$4"
  if [[ "$existed" == "true" ]]; then
    if [[ ! -f "$backup_file" || -L "$backup_file" ]]; then
      subflow_fail "缺少可信安装备份: ${backup_file}"
      return 1
    fi
    subflow_file_write_atomic "$target_file" "$backup_file" "$mode"
  else
    rm -f "$target_file"
  fi
}

subflow_install_restore_from_manifest() {
  local txn_dir="$1" manifest_file backup_dir
  local init binary_existed stamp_existed service_changed service_existed service_was_active service_target
  if ! subflow_install_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_install_manifest_path "$txn_dir")"
  backup_dir="$txn_dir/backup"
  init="$(jq -er '.init' "$manifest_file")" || return 1
  binary_existed="$(jq -er '.binary_existed' "$manifest_file")" || return 1
  stamp_existed="$(jq -er '.stamp_existed' "$manifest_file")" || return 1
  service_changed="$(jq -er '.service_changed' "$manifest_file")" || return 1
  service_existed="$(jq -er '.service_existed' "$manifest_file")" || return 1
  service_was_active="$(jq -er '.service_was_active' "$manifest_file")" || return 1
  service_target="$(jq -er '.service_target' "$manifest_file")" || return 1

  if [[ "$binary_existed" == "true" && ( ! -f "$backup_dir/sing-box" || -L "$backup_dir/sing-box" ) ]]; then
    subflow_fail "缺少可信安装备份: ${backup_dir}/sing-box"
    return 1
  fi
  if [[ "$stamp_existed" == "true" && ( ! -f "$backup_dir/installed-release" || -L "$backup_dir/installed-release" ) ]]; then
    subflow_fail "缺少可信安装备份: ${backup_dir}/installed-release"
    return 1
  fi
  if [[ "$service_changed" == "true" && "$service_existed" == "true" && ( ! -f "$backup_dir/service" || -L "$backup_dir/service" ) ]]; then
    subflow_fail "缺少可信安装备份: ${backup_dir}/service"
    return 1
  fi

  subflow_install_restore_file "$binary_existed" "$backup_dir/sing-box" "$SUBFLOW_SINGBOX_BIN" 755 || return 1
  subflow_install_restore_file "$stamp_existed" "$backup_dir/installed-release" "$SUBFLOW_VERSION_STAMP" 600 || return 1
  if [[ "$service_changed" == "true" ]]; then
    subflow_install_restore_file "$service_existed" "$backup_dir/service" "$service_target" "$([[ "$init" == "systemd" ]] && printf 644 || printf 755)" || return 1
    subflow_service_reload_after_restore "$init" "$service_was_active" "$service_existed" || return 1
  fi
}

subflow_install_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_install_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧版本"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_install_manager_entrypoint() {
  local source_file="${BASH_SOURCE[0]}" shortcut_file
  if [[ ! -r "$source_file" || "$SUBFLOW_MANAGER_TARGET" == *'"'* || "$SUBFLOW_MANAGER_TARGET" == *$'\n'* ]]; then
    subflow_fail "无法安装管理器入口"
    return 1
  fi
  subflow_file_write_atomic "$SUBFLOW_MANAGER_TARGET" "$source_file" 700 || return 1
  shortcut_file="$(mktemp)" || return 1
  printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$SUBFLOW_MANAGER_TARGET" >"$shortcut_file"
  if ! subflow_file_write_atomic "$SUBFLOW_SHORTCUT_PATH" "$shortcut_file" 755; then
    rm -f "$shortcut_file"
    return 1
  fi
  rm -f "$shortcut_file"
}

subflow_install_archive_binary() {
  local binary="$1" version="$2" target
  target="${SUBFLOW_BINARY_STORE_DIR}/${version}/sing-box"
  subflow_file_write_atomic "$target" "$binary" 755
}

subflow_install_version() {
  local requested_version="$1" version arch init expected_sha256 download_url
  local txn_dir candidate_file backup_dir service_target current_version stamp_candidate
  local binary_existed=false stamp_existed=false service_changed=false service_existed=false service_was_active=false

  subflow_require_root || return 1
  subflow_require_cmd curl jq sha256sum flock id uname mktemp cp chmod mv || return 1
  arch="$(subflow_detect_arch)" || return 1
  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || return 1
  fi
  subflow_service_target "$init" >/dev/null || return 1
  subflow_detect_pkg_manager >/dev/null || return 1
  if [[ -n "$requested_version" ]]; then
    version="$(subflow_release_normalize_version "$requested_version")" || return 1
  else
    version="$(subflow_release_latest)" || return 1
  fi
  expected_sha256="$(subflow_release_sha256 "$version" "$arch")" || return 1
  download_url="$(subflow_release_url "$version" "$arch")" || return 1

  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  mkdir -p "$SUBFLOW_STATE_DIR" "$SUBFLOW_BINARY_STORE_DIR" || {
    subflow_lock_release
    return 1
  }
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate_file="$txn_dir/sing-box"
  backup_dir="$txn_dir/backup"
  mkdir -p "$backup_dir" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }

  if ! curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$candidate_file" "$download_url"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "下载 sing-box 失败"
    return 1
  fi
  if ! subflow_install_verify_candidate "$candidate_file" "$version" "$expected_sha256"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  service_target="$(subflow_service_target "$init")" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  [[ -f "$SUBFLOW_SINGBOX_BIN" ]] && binary_existed=true
  [[ -f "$SUBFLOW_VERSION_STAMP" ]] && stamp_existed=true
  if [[ -f "$SUBFLOW_CONFIG_PATH" ]]; then
    service_changed=true
    [[ -f "$service_target" ]] && service_existed=true
    if subflow_service_is_active "$init"; then
      service_was_active=true
    fi
  fi

  if [[ "$binary_existed" == "true" ]]; then
    cp "$SUBFLOW_SINGBOX_BIN" "$backup_dir/sing-box" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
    chmod 600 "$backup_dir/sing-box" 2>/dev/null || true
  fi
  if [[ "$stamp_existed" == "true" ]]; then
    cp "$SUBFLOW_VERSION_STAMP" "$backup_dir/installed-release" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  if [[ "$service_existed" == "true" ]]; then
    cp "$service_target" "$backup_dir/service" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  subflow_install_write_manifest "$txn_dir" "$init" "$binary_existed" "$stamp_existed" \
    "$service_changed" "$service_existed" "$service_was_active" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  subflow_txn_begin "$txn_dir" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }

  if [[ "$binary_existed" == "true" ]]; then
    current_version="$(subflow_binary_version "$SUBFLOW_SINGBOX_BIN" 2>/dev/null || true)"
    if [[ -n "$current_version" ]] && ! subflow_install_archive_binary "$SUBFLOW_SINGBOX_BIN" "$current_version"; then
      subflow_install_rollback "$txn_dir" "无法保留旧版 sing-box"
      return 1
    fi
  fi
  if ! subflow_file_write_atomic "$SUBFLOW_SINGBOX_BIN" "$candidate_file" 755; then
    subflow_install_rollback "$txn_dir" "写入 sing-box 二进制失败"
    return 1
  fi
  if [[ "$service_changed" == "true" ]]; then
    if ! subflow_service_write_definition "$init" || ! subflow_service_enable_and_restart "$init"; then
      subflow_install_rollback "$txn_dir" "sing-box 服务启动失败"
      return 1
    fi
  else
    note "配置文件不存在，仅安装二进制和管理器入口"
  fi

  stamp_candidate="$txn_dir/installed-release"
  printf '%s\n' "$version" >"$stamp_candidate"
  if ! subflow_file_write_atomic "$SUBFLOW_VERSION_STAMP" "$stamp_candidate" 600 \
    || ! subflow_install_archive_binary "$candidate_file" "$version" \
    || ! subflow_install_manager_entrypoint; then
    subflow_install_rollback "$txn_dir" "安装配套文件失败"
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "sing-box ${version} 已安装"
}

cmd_install_dispatch() {
  local version="" option
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    case "$option" in
      --version)
        version="${2:-}"
        [[ -n "$version" ]] || { subflow_fail "--version 需要参数"; return 1; }
        shift 2
        ;;
      *)
        subflow_fail "未知 install 参数: ${option}"
        return 1
        ;;
    esac
  done
  subflow_install_version "$version"
}

cmd_update() {
  [[ "$#" -eq 0 ]] || { subflow_fail "update 不接受参数"; return 1; }
  subflow_install_version ""
}
# --- 81_protocols.sh ---
subflow_protocol_registry() {
  cat <<'EOF'
vless-reality|vless|tcp|443|yes
anytls|anytls|tcp|443|yes
shadowsocks-2022|shadowsocks|tcp,udp|8388|yes
trojan|trojan|tcp|443|yes
vmess-ws|vmess|tcp|10000|yes
vless-ws|vless|tcp|10001|yes
tuic|tuic|udp|443|yes
EOF
}

subflow_protocol_is_supported() {
  local protocol="$1" record
  while IFS= read -r record; do
    [[ "${record%%|*}" == "$protocol" ]] && return 0
  done < <(subflow_protocol_registry)
  return 1
}

subflow_protocol_validate_tag() {
  local tag="$1"
  if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    subflow_fail "协议标签不合法: ${tag}"
    return 1
  fi
}

subflow_protocol_validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    subflow_fail "端口不合法: ${port}"
    return 1
  fi
}

subflow_protocol_validate_server_name() {
  local server_name="$1"
  if [[ ${#server_name} -gt 253 || ! "$server_name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ \
    || "$server_name" != *.* || "$server_name" == *..* ]]; then
    subflow_fail "服务器名称不合法: ${server_name}"
    return 1
  fi
}

subflow_protocol_validate_email() {
  local email="$1"
  if [[ ${#email} -gt 254 || "$email" == *[[:space:]]* || "$email" != *@*.* ]]; then
    subflow_fail "ACME 邮箱不合法: ${email}"
    return 1
  fi
}

subflow_protocol_list() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if ! subflow_require_cmd python3; then
    subflow_lock_release
    return 1
  fi
  if [[ ! -f "$SUBFLOW_CONFIG_PATH" ]]; then
    subflow_lock_release
    subflow_fail "缺少文件: ${SUBFLOW_CONFIG_PATH}"
    return 1
  fi

  python3 - "$SUBFLOW_CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("标签 | 协议 | 端口 | 用户数")
for inbound in sorted(payload.get("inbounds", []), key=lambda item: str(item.get("tag", ""))):
    inbound_type = inbound.get("type", "unknown")
    transport_type = (inbound.get("transport") or {}).get("type")
    reality_enabled = ((inbound.get("tls") or {}).get("reality") or {}).get("enabled") is True
    if inbound_type == "vless" and reality_enabled:
        protocol = "vless-reality"
    elif inbound_type == "vless" and transport_type == "ws":
        protocol = "vless-ws"
    elif inbound_type == "vmess" and transport_type == "ws":
        protocol = "vmess-ws"
    elif inbound_type == "shadowsocks":
        protocol = "shadowsocks-2022"
    else:
        protocol = inbound_type
    print(f"{inbound.get('tag', '')} | {protocol} | {inbound.get('listen_port', '')} | {len(inbound.get('users', []))}")
PY
  local status=$?
  subflow_lock_release
  return $status
}

cmd_protocols_dispatch() {
  local subcmd="${1:-list}"
  shift || true
  case "$subcmd" in
    list)
      [[ "$#" -eq 0 ]] || { subflow_fail "protocols list 不接受参数"; return 1; }
      subflow_protocol_list
      ;;
    registry)
      [[ "$#" -eq 0 ]] || { subflow_fail "protocols registry 不接受参数"; return 1; }
      subflow_protocol_registry
      ;;
    add)
      cmd_protocols_add "$@"
      ;;
    update)
      cmd_protocols_update "$@"
      ;;
    delete)
      cmd_protocols_delete "$@"
      ;;
    *)
      subflow_fail "未知 protocols 子命令: ${subcmd}"
      return 1
      ;;
  esac
}
# --- 82_protocol_transaction.sh ---
subflow_protocol_txn_manifest_path() {
  printf '%s\n' "$1/protocol.manifest.json"
}

subflow_protocol_txn_write_manifest() {
  local txn_dir="$1" operation="$2" tag="$3" init="$4"
  local config_existed="$5" meta_existed="$6" index_existed="$7"
  local service_existed="$8" service_was_active="$9"
  local manifest_file service_target
  manifest_file="$(subflow_protocol_txn_manifest_path "$txn_dir")"
  service_target="$(subflow_service_target "$init")" || return 1

  python3 - "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_CONFIG_PATH" "$SUBFLOW_META_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" \
    "$service_target" "$operation" "$tag" "$init" "$config_existed" "$meta_existed" \
    "$index_existed" "$service_existed" "$service_was_active" <<'PY'
import json
import sys
from pathlib import Path


def boolean(value):
    if value not in {"true", "false"}:
        raise ValueError("invalid boolean")
    return value == "true"


(
    manifest_file,
    txn_dir,
    state_dir,
    config_target,
    meta_target,
    index_target,
    service_target,
    operation,
    tag,
    init,
    config_existed,
    meta_existed,
    index_existed,
    service_existed,
    service_was_active,
) = sys.argv[1:]

payload = {
    "version": 1,
    "kind": "protocol-config",
    "txn_dir": txn_dir,
    "state_dir": state_dir,
    "config_target": config_target,
    "meta_target": meta_target,
    "index_target": index_target,
    "service_target": service_target,
    "operation": operation,
    "tag": tag,
    "init": init,
    "config_backup": "backup/config.json",
    "meta_backup": "backup/meta.json",
    "index_backup": "backup/subscriptions.json",
    "service_backup": "backup/service",
    "config_existed": boolean(config_existed),
    "meta_existed": boolean(meta_existed),
    "index_existed": boolean(index_existed),
    "service_existed": boolean(service_existed),
    "service_was_active": boolean(service_was_active),
}
Path(manifest_file).write_text(
    json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_protocol_txn_manifest_is_valid() {
  local txn_dir="$1" manifest_file init expected_service_target
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_protocol_txn_manifest_path "$txn_dir")"
  if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
    subflow_fail "缺少可信协议恢复清单"
    return 1
  fi
  init="$(subflow_protocol_txn_manifest_field "$txn_dir" init)" || return 1
  expected_service_target="$(subflow_service_target "$init")" || return 1

  python3 - "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_CONFIG_PATH" "$SUBFLOW_META_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" \
    "$expected_service_target" <<'PY'
import json
import sys
from pathlib import Path

manifest_file, txn_dir, state_dir, config_target, meta_target, index_target, service_target = sys.argv[1:]
try:
    payload = json.loads(Path(manifest_file).read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)

expected = {
    "version": 1,
    "kind": "protocol-config",
    "txn_dir": txn_dir,
    "state_dir": state_dir,
    "config_target": config_target,
    "meta_target": meta_target,
    "index_target": index_target,
    "service_target": service_target,
    "config_backup": "backup/config.json",
    "meta_backup": "backup/meta.json",
    "index_backup": "backup/subscriptions.json",
    "service_backup": "backup/service",
}
if any(payload.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
if payload.get("init") not in {"systemd", "openrc"}:
    raise SystemExit(1)
if payload.get("operation") not in {"add", "update", "delete"}:
    raise SystemExit(1)
if not isinstance(payload.get("tag"), str):
    raise SystemExit(1)
for field in ("config_existed", "meta_existed", "index_existed", "service_existed", "service_was_active"):
    if type(payload.get(field)) is not bool:
        raise SystemExit(1)
PY
  if [[ "$?" -ne 0 ]]; then
    subflow_fail "非法协议恢复清单: ${manifest_file}"
    return 1
  fi
}

subflow_protocol_txn_manifest_field() {
  local txn_dir="$1" field="$2" manifest_file
  case "$field" in
    init|service_target|config_existed|meta_existed|index_existed|service_existed|service_was_active) ;;
    *) return 1 ;;
  esac
  manifest_file="$(subflow_protocol_txn_manifest_path "$txn_dir")"
  python3 - "$manifest_file" "$field" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = payload[sys.argv[2]]
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, str):
    print(value)
else:
    raise SystemExit(1)
PY
}

subflow_protocol_txn_restore_file() {
  local existed="$1" backup_file="$2" target_file="$3" mode="$4"
  if [[ "$existed" == "true" ]]; then
    if [[ ! -f "$backup_file" || -L "$backup_file" ]]; then
      subflow_fail "缺少可信协议事务备份: ${backup_file}"
      return 1
    fi
    subflow_file_write_atomic "$target_file" "$backup_file" "$mode"
  else
    rm -f "$target_file"
  fi
}

subflow_protocol_restore_from_manifest() {
  local txn_dir="$1" backup_dir
  local init service_target config_existed meta_existed index_existed service_existed service_was_active service_mode
  if ! subflow_protocol_txn_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  backup_dir="$txn_dir/backup"
  init="$(subflow_protocol_txn_manifest_field "$txn_dir" init)" || return 1
  service_target="$(subflow_protocol_txn_manifest_field "$txn_dir" service_target)" || return 1
  config_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" config_existed)" || return 1
  meta_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" meta_existed)" || return 1
  index_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" index_existed)" || return 1
  service_existed="$(subflow_protocol_txn_manifest_field "$txn_dir" service_existed)" || return 1
  service_was_active="$(subflow_protocol_txn_manifest_field "$txn_dir" service_was_active)" || return 1
  if [[ "$init" == "systemd" ]]; then service_mode=644; else service_mode=755; fi

  for entry in \
    "$config_existed:$backup_dir/config.json" \
    "$meta_existed:$backup_dir/meta.json" \
    "$index_existed:$backup_dir/subscriptions.json" \
    "$service_existed:$backup_dir/service"; do
    if [[ "${entry%%:*}" == "true" ]]; then
      local backup_path="${entry#*:}"
      if [[ ! -f "$backup_path" || -L "$backup_path" ]]; then
        subflow_fail "缺少可信协议事务备份: ${backup_path}"
        return 1
      fi
    fi
  done

  subflow_protocol_txn_restore_file "$config_existed" "$backup_dir/config.json" "$SUBFLOW_CONFIG_PATH" 600 || return 1
  subflow_protocol_txn_restore_file "$meta_existed" "$backup_dir/meta.json" "$SUBFLOW_META_PATH" 600 || return 1
  subflow_protocol_txn_restore_file "$index_existed" "$backup_dir/subscriptions.json" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" 600 || return 1
  subflow_protocol_txn_restore_file "$service_existed" "$backup_dir/service" "$service_target" "$service_mode" || return 1
  subflow_service_reload_after_restore "$init" "$service_was_active" "$service_existed"
}

subflow_protocol_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_protocol_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧配置"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_protocol_candidate_is_managed() {
  local txn_dir="$1" candidate="$2" txn_real candidate_parent
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  txn_real="$(cd "$txn_dir" && pwd -P)" || return 1
  candidate_parent="$(cd "$(dirname "$candidate")" && pwd -P)" || return 1
  [[ "$candidate_parent" == "$txn_real" ]]
}

subflow_protocol_backup_if_present() {
  local existed="$1" source_file="$2" backup_file="$3"
  if [[ "$existed" == "true" ]]; then
    cp "$source_file" "$backup_file"
  fi
}

subflow_protocol_apply_candidates() {
  local txn_dir="$1" operation="$2" tag="$3"
  local candidate_config="$4" candidate_meta="$5" candidate_index="$6"
  local init service_target backup_dir source operation_label
  local config_existed=false meta_existed=false index_existed=false service_existed=false service_was_active=false

  for source in "$candidate_config" "$candidate_meta" "$candidate_index"; do
    if ! subflow_protocol_candidate_is_managed "$txn_dir" "$source"; then
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      subflow_fail "候选协议文件不在受管事务目录"
      return 1
    fi
  done
  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || {
      subflow_txn_abort "$txn_dir" || true
      subflow_lock_release
      return 1
    }
  fi
  service_target="$(subflow_service_target "$init")" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }
  backup_dir="$txn_dir/backup"
  mkdir -p "$backup_dir" || {
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  }

  [[ -f "$SUBFLOW_CONFIG_PATH" ]] && config_existed=true
  [[ -f "$SUBFLOW_META_PATH" ]] && meta_existed=true
  [[ -f "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]] && index_existed=true
  [[ -f "$service_target" ]] && service_existed=true
  if subflow_service_is_active "$init"; then service_was_active=true; fi

  if ! subflow_protocol_backup_if_present "$config_existed" "$SUBFLOW_CONFIG_PATH" "$backup_dir/config.json" \
    || ! subflow_protocol_backup_if_present "$meta_existed" "$SUBFLOW_META_PATH" "$backup_dir/meta.json" \
    || ! subflow_protocol_backup_if_present "$index_existed" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$backup_dir/subscriptions.json" \
    || ! subflow_protocol_backup_if_present "$service_existed" "$service_target" "$backup_dir/service"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi
  chmod 600 "$backup_dir"/* 2>/dev/null || true

  if ! subflow_protocol_txn_write_manifest "$txn_dir" "$operation" "$tag" "$init" \
    "$config_existed" "$meta_existed" "$index_existed" "$service_existed" "$service_was_active" \
    || ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  if ! subflow_json_write_atomic "$SUBFLOW_CONFIG_PATH" "$candidate_config" \
    || ! subflow_json_write_atomic "$SUBFLOW_META_PATH" "$candidate_meta" \
    || ! subflow_json_write_atomic "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$candidate_index"; then
    subflow_protocol_rollback "$txn_dir" "协议文件写入失败"
    return 1
  fi
  if ! subflow_service_write_definition "$init" || ! subflow_service_enable_and_restart "$init"; then
    subflow_protocol_rollback "$txn_dir" "sing-box 服务应用失败"
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  case "$operation" in
    add) operation_label="新增" ;;
    update) operation_label="更新" ;;
    delete) operation_label="删除" ;;
  esac
  ok "协议 ${tag} 已${operation_label}"
}
# --- 83_reality.sh ---
subflow_protocol_reality_generate_keypair() {
  local output line private_key="" public_key="" value
  output="$("$SUBFLOW_SINGBOX_BIN" generate reality-keypair 2>&1)" || {
    subflow_fail "生成 Reality 密钥对失败"
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      PrivateKey:*)
        value="${line#*:}"
        private_key="${value#"${value%%[![:space:]]*}"}"
        ;;
      PublicKey:*)
        value="${line#*:}"
        public_key="${value#"${value%%[![:space:]]*}"}"
        ;;
    esac
  done <<<"$output"
  if [[ ! "$private_key" =~ ^[A-Za-z0-9_-]{40,64}$ || ! "$public_key" =~ ^[A-Za-z0-9_-]{40,64}$ ]]; then
    subflow_fail "Reality 密钥对输出格式无效"
    return 1
  fi
  printf '%s\n%s\n' "$private_key" "$public_key"
}

subflow_protocol_reality_generate_short_id() {
  local short_id
  short_id="$(openssl rand -hex 8)" || return 1
  if [[ ! "$short_id" =~ ^[0-9A-Fa-f]{16}$ ]]; then
    subflow_fail "生成 Reality short ID 失败"
    return 1
  fi
  printf '%s\n' "${short_id,,}"
}

subflow_protocol_prepare_base_files() {
  local candidate_config="$1" candidate_meta="$2"
  if [[ -f "$SUBFLOW_CONFIG_PATH" ]]; then
    subflow_json_require_object "$SUBFLOW_CONFIG_PATH" || return 1
    subflow_check_config_file "$SUBFLOW_CONFIG_PATH" || return 1
    cp "$SUBFLOW_CONFIG_PATH" "$candidate_config" || return 1
  else
    cat >"$candidate_config" <<'JSON'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON
  fi
  if [[ -f "$SUBFLOW_META_PATH" ]]; then
    subflow_json_require_object "$SUBFLOW_META_PATH" || return 1
    cp "$SUBFLOW_META_PATH" "$candidate_meta" || return 1
  else
    printf '{}\n' >"$candidate_meta"
  fi
}

subflow_protocol_reality_mutate_candidates() {
  local operation="$1" candidate_config="$2" candidate_meta="$3" tag="$4"
  local port="$5" server_name="$6" handshake_server="$7" handshake_port="$8"
  local private_key="$9" public_key="${10}" short_id="${11}"
  subflow_reality_mutator_source | python3 - "$operation" "$candidate_config" "$candidate_meta" \
    "$SUBFLOW_USERS_PATH" "$tag" "$port" "$server_name" "$handshake_server" \
    "$handshake_port" "$private_key" "$public_key" "$short_id"
}

subflow_protocol_discard_candidate() {
  local txn_dir="$1"
  subflow_txn_abort "$txn_dir" || true
  subflow_lock_release
}

subflow_protocol_vless_reality_mutate() {
  local operation="$1" tag="$2" port="$3" server_name="$4"
  local handshake_server="$5" handshake_port="$6"
  local txn_dir candidate_config candidate_meta candidate_index short_id="" private_key="" public_key=""
  local -a keypair=()

  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd jq python3 openssl || ! subflow_binary_exists; then
    subflow_lock_release
    if ! subflow_binary_exists; then subflow_fail "缺少 sing-box 二进制"; fi
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate_config="$txn_dir/config.json"
  candidate_meta="$txn_dir/meta.json"
  candidate_index="$txn_dir/subscriptions.json"
  if ! subflow_protocol_prepare_base_files "$candidate_config" "$candidate_meta"; then
    subflow_protocol_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$operation" == "add" ]]; then
    if ! mapfile -t keypair < <(subflow_protocol_reality_generate_keypair) || [[ ${#keypair[@]} -ne 2 ]]; then
      subflow_protocol_discard_candidate "$txn_dir"
      return 1
    fi
    private_key="${keypair[0]}"
    public_key="${keypair[1]}"
    short_id="$(subflow_protocol_reality_generate_short_id)" || {
      subflow_protocol_discard_candidate "$txn_dir"
      return 1
    }
  fi
  if ! subflow_protocol_reality_mutate_candidates "$operation" "$candidate_config" "$candidate_meta" \
    "$tag" "$port" "$server_name" "$handshake_server" "$handshake_port" \
    "$private_key" "$public_key" "$short_id"; then
    subflow_protocol_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_json_validate "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config" \
    || ! subflow_json_require_object "$candidate_meta" \
    || ! subflow_rebuild_generate_subscription_index_from_files \
      "$candidate_config" "$SUBFLOW_USERS_PATH" "$candidate_meta" "$candidate_index" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_protocol_discard_candidate "$txn_dir"
    subflow_fail "候选协议配置校验失败"
    return 1
  fi
  subflow_protocol_apply_candidates "$txn_dir" "$operation" "$tag" \
    "$candidate_config" "$candidate_meta" "$candidate_index"
}

cmd_protocols_add_vless_reality() {
  local tag="" port="443" server_name="" handshake_server="" handshake_port="443"
  local option value
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --tag) tag="$value" ;;
      --port) port="$value" ;;
      --server-name) server_name="$value" ;;
      --handshake-server) handshake_server="$value" ;;
      --handshake-port) handshake_port="$value" ;;
      *) subflow_fail "未知 protocols add 参数: ${option}"; return 1 ;;
    esac
    shift 2
  done
  [[ -n "$tag" ]] || { subflow_fail "缺少 --tag"; return 1; }
  [[ -n "$server_name" ]] || { subflow_fail "缺少 --server-name"; return 1; }
  [[ -n "$handshake_server" ]] || handshake_server="$server_name"
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_validate_port "$handshake_port" || return 1
  subflow_protocol_validate_server_name "$server_name" || return 1
  subflow_protocol_validate_server_name "$handshake_server" || return 1
  subflow_protocol_vless_reality_mutate add "$tag" "$port" "$server_name" "$handshake_server" "$handshake_port"
}

cmd_protocols_update_vless_reality() {
  local tag="${1:-}" port="" server_name="" handshake_server="" handshake_port="" option value changed=0
  shift || true
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --port) port="$value" ;;
      --server-name) server_name="$value" ;;
      --handshake-server) handshake_server="$value" ;;
      --handshake-port) handshake_port="$value" ;;
      *) subflow_fail "未知 protocols update 参数: ${option}"; return 1 ;;
    esac
    changed=1
    shift 2
  done
  (( changed == 1 )) || { subflow_fail "没有提供更新字段"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  [[ -z "$port" ]] || subflow_protocol_validate_port "$port" || return 1
  [[ -z "$handshake_port" ]] || subflow_protocol_validate_port "$handshake_port" || return 1
  [[ -z "$server_name" ]] || subflow_protocol_validate_server_name "$server_name" || return 1
  [[ -z "$handshake_server" ]] || subflow_protocol_validate_server_name "$handshake_server" || return 1
  subflow_protocol_vless_reality_mutate update "$tag" "$port" "$server_name" "$handshake_server" "$handshake_port"
}

cmd_protocols_delete_vless_reality() {
  local tag="${1:-}" confirmation="${2:-}"
  [[ -n "$tag" && "$#" -eq 2 && "$confirmation" == "YES" ]] \
    || { subflow_fail "用法: protocols delete <标签> YES"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_vless_reality_mutate delete "$tag" "" "" "" ""
}
# --- 83_shadowsocks.sh ---
subflow_protocol_shadowsocks_mutate_candidates() {
  local operation="$1" candidate_config="$2" candidate_meta="$3"
  local tag="$4" port="$5" method="$6"
  subflow_shadowsocks_mutator_source | python3 - "$operation" "$candidate_config" "$candidate_meta" \
    "$SUBFLOW_USERS_PATH" "$tag" "$port" "$method"
}

subflow_protocol_shadowsocks_mutate() {
  local operation="$1" tag="$2" port="$3" method="$4"
  local txn_dir candidate_config candidate_meta candidate_index
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd jq python3 || ! subflow_binary_exists; then
    subflow_lock_release
    if ! subflow_binary_exists; then subflow_fail "缺少 sing-box 二进制"; fi
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate_config="$txn_dir/config.json"
  candidate_meta="$txn_dir/meta.json"
  candidate_index="$txn_dir/subscriptions.json"
  if ! subflow_protocol_prepare_base_files "$candidate_config" "$candidate_meta" \
    || ! subflow_protocol_shadowsocks_mutate_candidates "$operation" "$candidate_config" "$candidate_meta" \
      "$tag" "$port" "$method"; then
    subflow_protocol_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_json_validate "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config" \
    || ! subflow_json_require_object "$candidate_meta" \
    || ! subflow_rebuild_generate_subscription_index_from_files \
      "$candidate_config" "$SUBFLOW_USERS_PATH" "$candidate_meta" "$candidate_index" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_protocol_discard_candidate "$txn_dir"
    subflow_fail "候选协议配置校验失败"
    return 1
  fi
  subflow_protocol_apply_candidates "$txn_dir" "$operation" "$tag" \
    "$candidate_config" "$candidate_meta" "$candidate_index"
}

cmd_protocols_add_shadowsocks_2022() {
  local tag="" port="8388" method="2022-blake3-aes-128-gcm" option value
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --tag) tag="$value" ;;
      --port) port="$value" ;;
      --method) method="$value" ;;
      *) subflow_fail "未知 Shadowsocks 2022 参数: ${option}"; return 1 ;;
    esac
    shift 2
  done
  [[ -n "$tag" ]] || { subflow_fail "缺少 --tag"; return 1; }
  case "$method" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
    *) subflow_fail "不支持的 Shadowsocks 2022 方法: ${method}"; return 1 ;;
  esac
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_shadowsocks_mutate add "$tag" "$port" "$method"
}

cmd_protocols_update_shadowsocks_2022() {
  local tag="${1:-}" port="" option value changed=0
  shift || true
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --port) port="$value" ;;
      *) subflow_fail "Shadowsocks 2022 更新仅支持 --port"; return 1 ;;
    esac
    changed=1
    shift 2
  done
  (( changed == 1 )) || { subflow_fail "没有提供更新字段"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_shadowsocks_mutate update "$tag" "$port" ""
}

cmd_protocols_delete_shadowsocks_2022() {
  local tag="${1:-}" confirmation="${2:-}"
  [[ -n "$tag" && "$#" -eq 2 && "$confirmation" == "YES" ]] \
    || { subflow_fail "用法: protocols delete <标签> YES"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_shadowsocks_mutate delete "$tag" "" ""
}
# --- 83_tls_protocols.sh ---
subflow_protocol_tls_mutate_candidates() {
  local operation="$1" protocol="$2" candidate_config="$3" candidate_meta="$4"
  local tag="$5" port="$6" domain="$7" email="$8"
  subflow_tls_protocol_mutator_source | python3 - "$operation" "$protocol" \
    "$candidate_config" "$candidate_meta" "$SUBFLOW_USERS_PATH" \
    "$SUBFLOW_ACME_CLOUDFLARE_SECRET_PATH" "$SUBFLOW_ACME_DATA_DIR" \
    "$tag" "$port" "$domain" "$email"
}

subflow_protocol_tls_mutate() {
  local operation="$1" protocol="$2" tag="$3" port="$4" domain="$5" email="$6"
  local txn_dir candidate_config candidate_meta candidate_index
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi
  if ! subflow_require_cmd jq python3 || ! subflow_binary_exists; then
    subflow_lock_release
    if ! subflow_binary_exists; then subflow_fail "缺少 sing-box 二进制"; fi
    return 1
  fi
  if [[ "$operation" != "delete" ]] && ! subflow_acme_cloudflare_validate; then
    subflow_lock_release
    subflow_fail "请先导入 Cloudflare ACME 凭据"
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi
  txn_dir="$(subflow_txn_dir_create)" || {
    subflow_lock_release
    return 1
  }
  candidate_config="$txn_dir/config.json"
  candidate_meta="$txn_dir/meta.json"
  candidate_index="$txn_dir/subscriptions.json"
  if ! subflow_protocol_prepare_base_files "$candidate_config" "$candidate_meta" \
    || ! subflow_protocol_tls_mutate_candidates "$operation" "$protocol" \
      "$candidate_config" "$candidate_meta" "$tag" "$port" "$domain" "$email"; then
    subflow_protocol_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_json_validate "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config" \
    || ! subflow_json_require_object "$candidate_meta" \
    || ! subflow_rebuild_generate_subscription_index_from_files \
      "$candidate_config" "$SUBFLOW_USERS_PATH" "$candidate_meta" "$candidate_index" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_protocol_discard_candidate "$txn_dir"
    subflow_fail "候选 TLS 协议配置校验失败"
    return 1
  fi
  subflow_protocol_apply_candidates "$txn_dir" "$operation" "$tag" \
    "$candidate_config" "$candidate_meta" "$candidate_index"
}

cmd_protocols_add_tls() {
  local protocol="$1" tag="" port="443" domain="" email="" option value
  shift || true
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --tag) tag="$value" ;;
      --port) port="$value" ;;
      --domain) domain="$value" ;;
      --email) email="$value" ;;
      *) subflow_fail "未知 ${protocol} 参数: ${option}"; return 1 ;;
    esac
    shift 2
  done
  [[ -n "$tag" ]] || { subflow_fail "缺少 --tag"; return 1; }
  [[ -n "$domain" ]] || { subflow_fail "缺少 --domain"; return 1; }
  [[ -n "$email" ]] || { subflow_fail "缺少 --email"; return 1; }
  subflow_protocol_validate_tag "$tag" || return 1
  subflow_protocol_validate_port "$port" || return 1
  subflow_protocol_validate_server_name "$domain" || return 1
  subflow_protocol_validate_email "$email" || return 1
  subflow_protocol_tls_mutate add "$protocol" "$tag" "$port" "$domain" "$email"
}

cmd_protocols_update_tls() {
  local protocol="$1" tag="$2" port="" domain="" email="" option value changed=0
  shift 2 || true
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    value="${2:-}"
    [[ -n "$value" ]] || { subflow_fail "${option} 需要参数"; return 1; }
    case "$option" in
      --port) port="$value" ;;
      --domain) domain="$value" ;;
      --email) email="$value" ;;
      *) subflow_fail "未知 ${protocol} 更新参数: ${option}"; return 1 ;;
    esac
    changed=1
    shift 2
  done
  (( changed == 1 )) || { subflow_fail "没有提供更新字段"; return 1; }
  [[ -z "$port" ]] || subflow_protocol_validate_port "$port" || return 1
  [[ -z "$domain" ]] || subflow_protocol_validate_server_name "$domain" || return 1
  [[ -z "$email" ]] || subflow_protocol_validate_email "$email" || return 1
  subflow_protocol_tls_mutate update "$protocol" "$tag" "$port" "$domain" "$email"
}

cmd_protocols_delete_tls() {
  local protocol="$1" tag="$2" confirmation="${3:-}"
  [[ "$#" -eq 3 && "$confirmation" == "YES" ]] \
    || { subflow_fail "用法: protocols delete <标签> YES"; return 1; }
  subflow_protocol_tls_mutate delete "$protocol" "$tag" "" "" ""
}
# --- 84_protocol_dispatch.sh ---
subflow_protocol_kind_for_tag() {
  local tag="$1"
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); matches=[item for item in data.get("inbounds", []) if item.get("tag") == sys.argv[2]]; len(matches) == 1 or sys.exit(1); item=matches[0]; kind=item.get("type"); reality=isinstance(item.get("tls"), dict) and isinstance(item["tls"].get("reality"), dict) and item["tls"]["reality"].get("enabled") is True; print("vless-reality" if kind == "vless" and reality else "shadowsocks-2022" if kind == "shadowsocks" and str(item.get("method", "")).startswith("2022-") else kind if kind in {"anytls", "trojan", "tuic"} else "unknown")' \
    "$SUBFLOW_CONFIG_PATH" "$tag"
}

cmd_protocols_add() {
  local protocol="${1:-}"
  shift || true
  case "$protocol" in
    vless-reality) cmd_protocols_add_vless_reality "$@" ;;
    shadowsocks-2022) cmd_protocols_add_shadowsocks_2022 "$@" ;;
    anytls|trojan|tuic) cmd_protocols_add_tls "$protocol" "$@" ;;
    *)
      subflow_fail "当前仅支持新增 vless-reality 或 shadowsocks-2022"
      return 1
      ;;
  esac
}

cmd_protocols_update() {
  local tag="${1:-}" protocol
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  protocol="$(subflow_protocol_kind_for_tag "$tag")" || {
    subflow_fail "未知协议标签: ${tag}"
    return 1
  }
  case "$protocol" in
    vless-reality) cmd_protocols_update_vless_reality "$@" ;;
    shadowsocks-2022) cmd_protocols_update_shadowsocks_2022 "$@" ;;
    anytls|trojan|tuic) cmd_protocols_update_tls "$protocol" "$@" ;;
    *) subflow_fail "协议暂不支持更新: ${tag}"; return 1 ;;
  esac
}

cmd_protocols_delete() {
  local tag="${1:-}" protocol
  [[ -n "$tag" ]] || { subflow_fail "缺少协议标签"; return 1; }
  protocol="$(subflow_protocol_kind_for_tag "$tag")" || {
    subflow_fail "未知协议标签: ${tag}"
    return 1
  }
  case "$protocol" in
    vless-reality) cmd_protocols_delete_vless_reality "$@" ;;
    shadowsocks-2022) cmd_protocols_delete_shadowsocks_2022 "$@" ;;
    anytls|trojan|tuic) cmd_protocols_delete_tls "$protocol" "$@" ;;
    *) subflow_fail "协议暂不支持删除: ${tag}"; return 1 ;;
  esac
}
# --- 84_rebuild.sh ---
subflow_rebuild_jq_program() {
  cat <<'JQ'
def owner_from_name:
  if type == "string" and test("@"); then split("@")[ -1 ] else "admin" end;

def user_name_from_name:
  if type == "string" and test("@"); then split("@")[ -1 ] else "admin" end;

def safe_user_entry:
  {
    name: .name,
    username: (.name | user_name_from_name),
    uuid: (.uuid // empty),
    password: (.password // empty),
    flow: (.flow // empty)
  }
  | with_entries(select(.value != null and .value != ""));

def selected_inbound_users($username):
  [ .users[]? | select((.name | owner_from_name) == $username) | safe_user_entry ];

def selected_transport:
  if .transport? == null then {}
  else {transport: {type: .transport.type, path: .transport.path} | with_entries(select(.value != null))}
  end;

def selected_tls:
  if .tls? == null then {}
  else
    {tls: ({server_name: .tls.server_name}
      + (if .tls.reality? == null then {} else {reality: {enabled: .tls.reality.enabled, short_id: (.tls.reality.short_id // [])}} end))
      | with_entries(select(.value != null))}
  end;

def selected_inbound($username):
  . as $inbound
  | (selected_inbound_users($username)) as $users
  | if ($users | length) == 0 then empty
    else
      {
        type: $inbound.type,
        tag: $inbound.tag,
        listen_port: $inbound.listen_port,
        users: $users
      }
      + (if $inbound.type == "shadowsocks" and $inbound.method? != null then {method: $inbound.method} else {} end)
      + (if $inbound.type == "shadowsocks" and $inbound.password? != null then {password: $inbound.password} else {} end)
      + selected_transport
      + selected_tls
    end;

def selected_meta($username):
  reduce ($config.inbounds[]? | select(.tag? != null)) as $inbound ({};
    if ($inbound.type == "vless")
      and (($inbound.tls.reality.enabled // false) == true)
      and ([ $inbound.users[]? | select((.name | owner_from_name) == $username) ] | length > 0)
      and ($meta[$inbound.tag].public_key? != null)
    then . + {($inbound.tag): {public_key: $meta[$inbound.tag].public_key}}
    else . end);

{
  schema_version: 1,
  users: (
    ($users.users // {})
    | to_entries
    | sort_by(.key)
    | reduce .[] as $entry ({},
        . + {
          ($entry.key): {
            usage: (
              $entry.value
              | {
                  enabled: (.enabled // true),
                  disabled_reason: (.disabled_reason // null),
                  quota_gb: (.quota_gb // 0),
                  used_up_bytes: (.used_up_bytes // 0),
                  used_down_bytes: (.used_down_bytes // 0),
                  manual_added_bytes: (.manual_added_bytes // 0),
                  last_live_up_bytes: (.last_live_up_bytes // 0),
                  last_live_down_bytes: (.last_live_down_bytes // 0),
                  last_reset_period: (.last_reset_period // ""),
                  reset_day: (.reset_day // 0),
                  expire_at: (.expire_at // "0"),
                  allow_all_nodes: (.allow_all_nodes // true),
                  nodes: (.nodes // [])
                }
            ),
            inbounds: [ $config.inbounds[]? | selected_inbound($entry.key) ],
            meta: selected_meta($entry.key)
          }
        }
      )
  )
}
JQ
}

subflow_rebuild_generate_subscription_index_from_files() {
  local config_file="$1"
  local users_file="$2"
  local meta_file="$3"
  local candidate_file="$4"
  local jq_program

  subflow_require_cmd jq || return 1
  subflow_json_require_file "$config_file" || return 1
  subflow_json_require_file "$users_file" || return 1
  subflow_json_require_file "$meta_file" || return 1
  subflow_json_require_object "$config_file" || return 1
  subflow_json_require_schema_v1 "$users_file" || return 1
  subflow_json_require_object "$meta_file" || return 1
  jq_program="$(subflow_rebuild_jq_program)" || return 1

  if ! jq -n \
    --argfile config "$config_file" \
    --argfile users "$users_file" \
    --argfile meta "$meta_file" \
    "$jq_program" >"$candidate_file"; then
    return 1
  fi

  subflow_json_validate "$candidate_file" || return 1
  subflow_check_subscription_index_file "$candidate_file" || return 1
}

subflow_rebuild_generate_subscription_index_for_users_file() {
  local users_file="$1"
  local candidate_file="$2"

  subflow_rebuild_generate_subscription_index_from_files \
    "$SUBFLOW_CONFIG_PATH" \
    "$users_file" \
    "$SUBFLOW_META_PATH" \
    "$candidate_file"
}

cmd_rebuild() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi

  local txn_dir candidate_file output_file
  if ! txn_dir="$(subflow_txn_dir_create)"; then
    subflow_lock_release
    return 1
  fi
  candidate_file="${txn_dir}/subscriptions.json"

  if ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  if ! subflow_rebuild_generate_subscription_index_from_files \
    "$SUBFLOW_CONFIG_PATH" \
    "$SUBFLOW_USERS_PATH" \
    "$SUBFLOW_META_PATH" \
    "$candidate_file"; then
    subflow_txn_abort "$txn_dir"
    subflow_lock_release
    return 1
  fi

  if subflow_binary_exists && ! "$SUBFLOW_SINGBOX_BIN" check -c "$SUBFLOW_CONFIG_PATH" >/dev/null 2>&1; then
    subflow_txn_abort "$txn_dir"
    subflow_lock_release
    subflow_fail "sing-box check 失败，未写入订阅索引"
    return 1
  fi

  output_file="$SUBFLOW_SUBSCRIPTION_INDEX_PATH"
  if ! subflow_json_write_atomic "$output_file" "$candidate_file"; then
    subflow_txn_abort "$txn_dir"
    subflow_lock_release
    return 1
  fi
  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "订阅索引已重建"
}

# --- 85_users.sh ---
subflow_users_require_backend() {
  subflow_require_cmd jq python3
}

subflow_users_validate_username() {
  local username="$1"
  if ! subflow_is_valid_username "$username"; then
    subflow_fail "用户名不合法: ${username}"
    return 1
  fi
}

subflow_users_validate_non_negative_integer() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    subflow_fail "整数不合法: ${value}"
    return 1
  fi
}

subflow_users_validate_reset_day() {
  local value="$1"
  if ! subflow_users_validate_non_negative_integer "$value"; then
    return 1
  fi
  if [[ "$value" -lt 0 || "$value" -gt 32 ]]; then
    subflow_fail "重置日不合法: ${value}"
    return 1
  fi
}

subflow_users_validate_expire_at() {
  local value="$1"
  if [[ "$value" == "0" ]]; then
    return 0
  fi
  if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    subflow_fail "到期日期不合法: ${value}"
    return 1
  fi
  if ! python3 -c 'from datetime import date; import sys; y, m, d = map(int, sys.argv[1].split("-")); date(y, m, d)' "$value" >/dev/null 2>&1; then
    subflow_fail "到期日期不合法: ${value}"
    return 1
  fi
}

subflow_users_username_exists() {
  local username="$1"
  python3 - "$SUBFLOW_USERS_PATH" "$username" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
sys.exit(0 if sys.argv[2] in data.get('users', {}) else 1)
PY
}

subflow_users_list() {
  if ! subflow_lock_acquire; then
    return 1
  fi
  if ! subflow_users_require_backend; then
    subflow_lock_release
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi

  python3 - "$SUBFLOW_USERS_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
users = payload.get('users', {})
print('用户名 | 状态 | quota_gb | reset_day | expire_at')
for username in sorted(users):
    entry = users[username]
    enabled = '启用' if entry.get('enabled', True) else '停用'
    print(f"{username} | {enabled} | quota={entry.get('quota_gb', 0)} | reset_day={entry.get('reset_day', 0)} | expire_at={entry.get('expire_at', '0')}")
PY
  local status=$?
  subflow_lock_release
  return $status
}

subflow_users_txn_manifest_path() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/recovery.manifest.json"
}

subflow_users_txn_backup_dir() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup"
}

subflow_users_txn_users_backup() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup/users.json"
}

subflow_users_txn_index_backup() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup/subscriptions.json"
}

subflow_users_txn_config_backup() {
  local txn_dir="$1"
  printf '%s\n' "${txn_dir}/backup/config.json"
}

subflow_users_manifest_tool() {
  subflow_user_transaction_manifest_source | python3 - "$@"
}

subflow_users_txn_write_manifest() {
  local txn_dir="$1" operation="$2" username="$3"
  local users_existed="$4" index_existed="$5" config_existed="$6"
  local config_changed="$7" service_existed="$8" service_was_active="$9"
  local init="${10}" service_target="${11}" manifest_file
  manifest_file="$(subflow_users_txn_manifest_path "$txn_dir")"
  if ! subflow_users_manifest_tool write "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_USERS_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$SUBFLOW_CONFIG_PATH" \
    "$service_target" "$init" "$operation" "$username" "$users_existed" "$index_existed" \
    "$config_existed" "$config_changed" "$service_existed" "$service_was_active"; then
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
}

subflow_users_manifest_field() {
  local txn_dir="$1" field="$2"
  subflow_users_manifest_tool field "$(subflow_users_txn_manifest_path "$txn_dir")" "$field"
}

subflow_users_manifest_is_valid() {
  local txn_dir="$1" manifest_file version init="" expected_service_target=""
  if ! subflow_txn_require_managed "$txn_dir"; then
    return 1
  fi
  manifest_file="$(subflow_users_txn_manifest_path "$txn_dir")"
  if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
    subflow_fail "缺少可信用户恢复清单"
    return 1
  fi
  version="$(subflow_users_manifest_field "$txn_dir" version)" || return 1
  if [[ "$version" == "2" ]]; then
    init="$(subflow_users_manifest_field "$txn_dir" init)" || return 1
    expected_service_target="$(subflow_service_target "$init")" || return 1
  fi
  if ! subflow_users_manifest_tool validate "$manifest_file" "$txn_dir" "$SUBFLOW_STATE_DIR" \
    "$SUBFLOW_USERS_PATH" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$SUBFLOW_CONFIG_PATH" \
    "$expected_service_target"; then
    subflow_fail "非法恢复清单: ${manifest_file}"
    return 1
  fi
}

subflow_users_restore_file() {
  local existed="$1" backup_file="$2" target_file="$3"
  if [[ "$existed" == "true" ]]; then
    if [[ ! -f "$backup_file" || -L "$backup_file" ]]; then
      subflow_fail "缺少可信事务备份: ${backup_file}"
      return 1
    fi
    subflow_json_write_atomic "$target_file" "$backup_file"
  else
    rm -f "$target_file"
  fi
}

subflow_users_restore_from_manifest() {
  local txn_dir="$1" version users_existed index_existed users_backup index_backup
  local config_changed=false config_existed=false config_backup
  local init="" service_existed=false service_was_active=false
  if ! subflow_users_manifest_is_valid "$txn_dir"; then
    return 1
  fi
  version="$(subflow_users_manifest_field "$txn_dir" version)" || return 1
  users_existed="$(subflow_users_manifest_field "$txn_dir" users_existed)" || return 1
  index_existed="$(subflow_users_manifest_field "$txn_dir" index_existed)" || return 1
  users_backup="$(subflow_users_txn_users_backup "$txn_dir")"
  index_backup="$(subflow_users_txn_index_backup "$txn_dir")"
  config_backup="$(subflow_users_txn_config_backup "$txn_dir")"
  if [[ "$version" == "2" ]]; then
    config_changed="$(subflow_users_manifest_field "$txn_dir" config_changed)" || return 1
    config_existed="$(subflow_users_manifest_field "$txn_dir" config_existed)" || return 1
    init="$(subflow_users_manifest_field "$txn_dir" init)" || return 1
    service_existed="$(subflow_users_manifest_field "$txn_dir" service_existed)" || return 1
    service_was_active="$(subflow_users_manifest_field "$txn_dir" service_was_active)" || return 1
  fi
  if [[ "$users_existed" == "true" && ( ! -f "$users_backup" || -L "$users_backup" ) ]]; then
    subflow_fail "缺少可信事务备份: ${users_backup}"
    return 1
  fi
  if [[ "$index_existed" == "true" && ( ! -f "$index_backup" || -L "$index_backup" ) ]]; then
    subflow_fail "缺少可信事务备份: ${index_backup}"
    return 1
  fi
  if [[ "$config_changed" == "true" && "$config_existed" == "true" \
    && ( ! -f "$config_backup" || -L "$config_backup" ) ]]; then
    subflow_fail "缺少可信事务备份: ${config_backup}"
    return 1
  fi
  subflow_users_restore_file "$users_existed" "$users_backup" "$SUBFLOW_USERS_PATH" || return 1
  subflow_users_restore_file "$index_existed" "$index_backup" "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" || return 1
  if [[ "$config_changed" == "true" ]]; then
    subflow_users_restore_file "$config_existed" "$config_backup" "$SUBFLOW_CONFIG_PATH" || return 1
    subflow_service_reload_after_restore "$init" "$service_was_active" "$service_existed"
  fi
}

subflow_users_write_candidate_file() {
  local operation="$1"
  local source_file="$2"
  local candidate_file="$3"
  local username="$4"
  local quota_gb="${5:-}"
  local reset_day="${6:-}"
  local expire_at="${7:-}"

  case "$operation" in
    add)
      jq --arg u "$username" --argjson quota "$quota_gb" --argjson reset_day "$reset_day" --arg expire "$expire_at" '
        .schema_version = 1
        | .users[$u] = {
            enabled: true,
            disabled_reason: null,
            quota_gb: $quota,
            used_up_bytes: 0,
            used_down_bytes: 0,
            manual_added_bytes: 0,
            last_live_up_bytes: 0,
            last_live_down_bytes: 0,
            last_reset_period: "",
            reset_day: $reset_day,
            expire_at: $expire,
            allow_all_nodes: true,
            nodes: []
          }
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    enable)
      jq --arg u "$username" '
        .users[$u].enabled = true
        | .users[$u].disabled_reason = null
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    disable)
      jq --arg u "$username" '
        .users[$u].enabled = false
        | .users[$u].disabled_reason = "manual"
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    delete)
      jq --arg u "$username" '
        del(.users[$u])
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    set-quota)
      jq --arg u "$username" --argjson quota "$quota_gb" '
        .users[$u].quota_gb = $quota
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    set-expire)
      jq --arg u "$username" --arg expire "$expire_at" '
        .users[$u].expire_at = $expire
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    set-reset-day)
      jq --arg u "$username" --argjson reset_day "$reset_day" '
        (.users[$u].reset_day // 0) as $old_reset
        | .users[$u].reset_day = $reset_day
        | if $old_reset != $reset_day then .users[$u].last_reset_period = "" else . end
        | .users |= (to_entries | sort_by(.key) | from_entries)
      ' "$source_file" >"$candidate_file"
      ;;
    *)
      subflow_fail "未知用户操作: ${operation}"
      return 1
      ;;
  esac
}

subflow_users_operation_changes_config() {
  case "$1" in
    add|enable|disable|delete) return 0 ;;
    *) return 1 ;;
  esac
}

subflow_users_write_candidate_config() {
  local operation="$1" candidate_config="$2" candidate_users="$3" username="$4"
  cp "$SUBFLOW_CONFIG_PATH" "$candidate_config" || return 1
  subflow_user_config_mutator_source | python3 - "$operation" "$candidate_config" "$candidate_users" "$username"
}

subflow_users_discard_candidate() {
  local txn_dir="$1"
  subflow_txn_abort "$txn_dir" || true
  subflow_lock_release
}

subflow_users_rollback() {
  local txn_dir="$1" reason="$2"
  if subflow_users_restore_from_manifest "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    subflow_fail "${reason}，已恢复旧状态"
    return 1
  fi
  subflow_lock_release
  subflow_fail "${reason}，自动恢复失败；请运行 recover"
  return 1
}

subflow_users_apply_mutation() {
  local operation="$1"
  local username="$2"
  local quota_gb="${3:-}"
  local reset_day="${4:-}"
  local expire_at="${5:-}"
  local txn_dir candidate_users candidate_config candidate_index
  local users_existed index_existed config_existed
  local config_changed=false service_existed=false service_was_active=false
  local init service_target

  if ! subflow_lock_acquire; then
    return 1
  fi
  if subflow_txn_has_pending; then
    subflow_lock_release
    subflow_fail "检测到未完成事务，请先恢复或人工处理"
    return 1
  fi

  if ! subflow_users_require_backend; then
    subflow_lock_release
    return 1
  fi
  if ! subflow_json_require_schema_v1 "$SUBFLOW_USERS_PATH"; then
    subflow_lock_release
    return 1
  fi
  if [[ -e "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]]; then
    if ! subflow_json_require_schema_v1 "$SUBFLOW_SUBSCRIPTION_INDEX_PATH"; then
      subflow_lock_release
      return 1
    fi
  fi
  if ! subflow_json_require_object "$SUBFLOW_CONFIG_PATH" \
    || ! subflow_check_config_file "$SUBFLOW_CONFIG_PATH" \
    || ! subflow_json_require_object "$SUBFLOW_META_PATH"; then
    subflow_lock_release
    return 1
  fi
  if ! subflow_binary_exists; then
    subflow_lock_release
    subflow_fail "缺少 sing-box 二进制"
    return 1
  fi

  if ! subflow_users_validate_username "$username"; then
    subflow_lock_release
    return 1
  fi

  case "$operation" in
    add)
      if [[ "$username" == "admin" ]]; then
        subflow_lock_release
        subflow_fail "admin 不能新增"
        return 1
      fi
      if ! subflow_users_validate_non_negative_integer "$quota_gb"; then
        subflow_lock_release
        return 1
      fi
      if ! subflow_users_validate_reset_day "$reset_day"; then
        subflow_lock_release
        return 1
      fi
      if ! subflow_users_validate_expire_at "$expire_at"; then
        subflow_lock_release
        return 1
      fi
      if subflow_users_username_exists "$username"; then
        subflow_lock_release
        subflow_fail "用户已存在: ${username}"
        return 1
      fi
      ;;
    enable|disable|set-quota|set-expire|set-reset-day|delete)
      if ! subflow_users_username_exists "$username"; then
        subflow_lock_release
        subflow_fail "未知用户: ${username}"
        return 1
      fi
      ;;
  esac

  if [[ "$operation" == "delete" && "$username" == "admin" ]]; then
    subflow_lock_release
    subflow_fail "admin 不能删除"
    return 1
  fi

  case "$operation" in
    set-quota)
      if ! subflow_users_validate_non_negative_integer "$quota_gb"; then
        subflow_lock_release
        return 1
      fi
      ;;
    set-expire)
      if ! subflow_users_validate_expire_at "$expire_at"; then
        subflow_lock_release
        return 1
      fi
      ;;
    set-reset-day)
      if ! subflow_users_validate_reset_day "$reset_day"; then
        subflow_lock_release
        return 1
      fi
      ;;
  esac

  init="${SUBFLOW_INIT:-}"
  if [[ -z "$init" ]]; then
    init="$(subflow_detect_init)" || {
      subflow_lock_release
      return 1
    }
  fi
  service_target="$(subflow_service_target "$init")" || {
    subflow_lock_release
    return 1
  }
  if [[ -f "$service_target" ]]; then
    service_existed=true
    if subflow_service_is_active "$init"; then
      service_was_active=true
    fi
  fi
  if subflow_users_operation_changes_config "$operation"; then
    config_changed=true
    if [[ "$service_existed" != "true" ]]; then
      subflow_lock_release
      subflow_fail "sing-box 服务定义缺失: ${service_target}"
      return 1
    fi
  fi

  if ! txn_dir="$(subflow_txn_dir_create)"; then
    subflow_lock_release
    return 1
  fi
  candidate_users="${txn_dir}/users.json"
  candidate_config="${txn_dir}/config.json"
  candidate_index="${txn_dir}/subscriptions.json"
  users_existed="false"
  index_existed="false"
  config_existed="false"
  [[ -f "$SUBFLOW_USERS_PATH" ]] && users_existed="true"
  [[ -f "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" ]] && index_existed="true"
  [[ -f "$SUBFLOW_CONFIG_PATH" ]] && config_existed="true"

  if ! subflow_users_write_candidate_file "$operation" "$SUBFLOW_USERS_PATH" "$candidate_users" "$username" "$quota_gb" "$reset_day" "$expire_at"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_users_write_candidate_config "$operation" "$candidate_config" "$candidate_users" "$username" \
    || ! subflow_json_require_schema_v1 "$candidate_users" \
    || ! subflow_json_require_object "$candidate_config" \
    || ! subflow_check_config_file "$candidate_config"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if ! subflow_rebuild_generate_subscription_index_from_files \
    "$candidate_config" "$candidate_users" "$SUBFLOW_META_PATH" "$candidate_index" \
    || ! "$SUBFLOW_SINGBOX_BIN" check -c "$candidate_config" >/dev/null 2>&1; then
    subflow_users_discard_candidate "$txn_dir"
    subflow_fail "候选用户配置校验失败，未写入现有状态"
    return 1
  fi

  if ! mkdir -p "$(subflow_users_txn_backup_dir "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$users_existed" == "true" ]] \
    && ! cp "$SUBFLOW_USERS_PATH" "$(subflow_users_txn_users_backup "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$index_existed" == "true" ]] \
    && ! cp "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$(subflow_users_txn_index_backup "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  if [[ "$config_changed" == "true" ]] \
    && ! cp "$SUBFLOW_CONFIG_PATH" "$(subflow_users_txn_config_backup "$txn_dir")"; then
    subflow_users_discard_candidate "$txn_dir"
    return 1
  fi
  chmod 600 "$(subflow_users_txn_backup_dir "$txn_dir")"/* 2>/dev/null || true

  if ! subflow_users_txn_write_manifest "$txn_dir" "$operation" "$username" \
    "$users_existed" "$index_existed" "$config_existed" "$config_changed" \
    "$service_existed" "$service_was_active" "$init" "$service_target" \
    || ! subflow_txn_begin "$txn_dir"; then
    subflow_txn_abort "$txn_dir" || true
    subflow_lock_release
    return 1
  fi

  if ! subflow_json_write_atomic "$SUBFLOW_USERS_PATH" "$candidate_users"; then
    subflow_users_rollback "$txn_dir" "用户库写入失败"
    return 1
  fi
  if [[ "$config_changed" == "true" ]] \
    && ! subflow_json_write_atomic "$SUBFLOW_CONFIG_PATH" "$candidate_config"; then
    subflow_users_rollback "$txn_dir" "sing-box 用户配置写入失败"
    return 1
  fi
  if ! subflow_json_write_atomic "$SUBFLOW_SUBSCRIPTION_INDEX_PATH" "$candidate_index"; then
    subflow_users_rollback "$txn_dir" "订阅索引写入失败"
    return 1
  fi
  if [[ "$config_changed" == "true" ]] \
    && ! subflow_service_apply_config_transaction "$init" "$service_was_active"; then
    subflow_users_rollback "$txn_dir" "sing-box 用户配置应用失败"
    return 1
  fi

  if ! subflow_txn_commit "$txn_dir" || ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "用户 ${username} 已更新"
}

cmd_users_add() {
  local username="$1"
  local quota_gb="$2"
  local reset_day="$3"
  local expire_at="$4"
  subflow_users_apply_mutation add "$username" "$quota_gb" "$reset_day" "$expire_at"
}

cmd_users_enable() {
  subflow_users_apply_mutation enable "$1"
}

cmd_users_disable() {
  subflow_users_apply_mutation disable "$1"
}

cmd_users_delete() {
  subflow_users_apply_mutation delete "$1"
}

cmd_users_set_quota() {
  subflow_users_apply_mutation set-quota "$1" "$2"
}

cmd_users_set_expire() {
  subflow_users_apply_mutation set-expire "$1" "" "" "$2"
}

cmd_users_set_reset_day() {
  subflow_users_apply_mutation set-reset-day "$1" "" "$2"
}

# --- 86_recover.sh ---
subflow_txn_find_pending_dir() {
  local txn_dir pending_count=0 found_dir=""
  for txn_dir in "${SUBFLOW_STATE_DIR}"/.txn.*; do
    [[ -d "$txn_dir" ]] || continue
    if [[ -e "${txn_dir}/recovery.pending" ]]; then
      found_dir="$txn_dir"
      pending_count=$((pending_count + 1))
    fi
  done
  if (( pending_count == 0 )); then
    return 1
  fi
  if (( pending_count > 1 )); then
    subflow_fail "发现多个未完成事务"
    return 2
  fi
  printf '%s\n' "$found_dir"
}

cmd_recover() {
  local txn_dir find_status

  if ! subflow_lock_acquire; then
    return 1
  fi
  if txn_dir="$(subflow_txn_find_pending_dir)"; then
    :
  else
    find_status=$?
    subflow_lock_release
    if (( find_status == 1 )); then
      ok "没有待恢复事务"
      return 0
    fi
    return "$find_status"
  fi

  if ! subflow_require_cmd jq; then
    subflow_lock_release
    return 1
  fi

  if [[ -f "$(subflow_acme_rotation_manifest_path "$txn_dir")" ]]; then
    if ! subflow_require_cmd python3 || ! subflow_acme_rotation_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  elif [[ -f "$(subflow_install_manifest_path "$txn_dir")" ]]; then
    if ! subflow_install_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  elif [[ -f "$(subflow_protocol_txn_manifest_path "$txn_dir")" ]]; then
    if ! subflow_require_cmd python3 || ! subflow_protocol_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  elif [[ -f "$(subflow_users_txn_manifest_path "$txn_dir")" ]]; then
    if ! subflow_users_restore_from_manifest "$txn_dir"; then
      subflow_lock_release
      return 1
    fi
  else
    subflow_lock_release
    subflow_fail "未识别的待恢复事务"
    return 1
  fi

  if ! subflow_txn_abort "$txn_dir"; then
    subflow_lock_release
    return 1
  fi
  subflow_lock_release
  ok "事务已恢复"
}

# --- 90_cli.sh ---
subflow_print_menu() {
  banner
  printf '%b\n' "  ${C_BOLD}主菜单${C_RESET}"
  printf '%b\n' "  1. 安装或更新 sing-box"
  printf '%b\n' "  2. 协议管理"
  printf '%b\n' "  3. 用户管理"
  printf '%b\n' "  4. 中转与落地（后续里程碑）"
  printf '%b\n' "  5. WARP 分流（后续里程碑）"
  printf '%b\n' "  6. 导出和重建订阅索引"
  printf '%b\n' "  7. 系统状态与诊断"
  printf '%b\n' "  8. 卸载运行组件并保留数据（后续里程碑）"
  printf '%b\n' "  0. 退出"
}

subflow_menu_once() {
  subflow_print_menu
  if [[ -t 0 ]]; then
    printf '%b' "  ${C_GREY}请选择 [0-8]: ${C_RESET}"
    local choice
    if ! read -r choice; then
      return 0
    fi
    case "$choice" in
      0) return 0 ;;
      6) cmd_rebuild ;;
      7) cmd_status ; cmd_doctor ;;
      1)
        if subflow_binary_exists; then
          cmd_update
        else
          cmd_install_dispatch
        fi
        ;;
      2) subflow_protocol_list ;;
      3) subflow_users_list ;;
      4|5|8)
        warn "该功能将在后续里程碑实现"
        return 1
        ;;
      *)
        warn "未知选项"
        return 1
        ;;
    esac
  fi
  return 0
}

cmd_users_dispatch() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    list)
      subflow_users_list
      ;;
    add)
      local username quota_gb="0" reset_day="0" expire_at="0" option value
      username="${1:-}"
      shift || true
      [[ -n "$username" ]] || { err "缺少用户名"; return 1; }
      while [[ "$#" -gt 0 ]]; do
        option="$1"
        case "$option" in
          --quota)
            value="${2:-}"
            [[ -n "$value" ]] || { err "--quota 需要参数"; return 1; }
            quota_gb="$value"
            shift 2
            ;;
          --reset-day)
            value="${2:-}"
            [[ -n "$value" ]] || { err "--reset-day 需要参数"; return 1; }
            reset_day="$value"
            shift 2
            ;;
          --expire)
            value="${2:-}"
            [[ -n "$value" ]] || { err "--expire 需要参数"; return 1; }
            expire_at="$value"
            shift 2
            ;;
          *)
            err "未知参数: ${option}"
            return 1
            ;;
        esac
      done
      cmd_users_add "$username" "$quota_gb" "$reset_day" "$expire_at"
      ;;
    enable|disable|delete)
      local username="${1:-}"
      [[ -n "$username" ]] || { err "缺少用户名"; return 1; }
      case "$subcmd" in
        enable) cmd_users_enable "$username" ;;
        disable) cmd_users_disable "$username" ;;
        delete)
          [[ "$#" -eq 2 && "${2:-}" == "YES" ]] \
            || { err "用法: users delete <用户名> YES"; return 1; }
          cmd_users_delete "$username"
          ;;
      esac
      ;;
    set-quota)
      local username="${1:-}" quota_gb="${2:-}"
      [[ -n "$username" && -n "$quota_gb" ]] || { err "参数不足"; return 1; }
      cmd_users_set_quota "$username" "$quota_gb"
      ;;
    set-expire)
      local username="${1:-}" expire_at="${2:-}"
      [[ -n "$username" && -n "$expire_at" ]] || { err "参数不足"; return 1; }
      cmd_users_set_expire "$username" "$expire_at"
      ;;
    set-reset-day)
      local username="${1:-}" reset_day="${2:-}"
      [[ -n "$username" && -n "$reset_day" ]] || { err "参数不足"; return 1; }
      cmd_users_set_reset_day "$username" "$reset_day"
      ;;
    *)
      err "未知 users 子命令: ${subcmd}"
      return 1
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  local arg2="${2:-}"

  case "$cmd" in
    "")
      subflow_menu_once
      ;;
    status)
      cmd_status
      ;;
    doctor)
      cmd_doctor
      ;;
    check)
      cmd_check
      ;;
    rebuild)
      cmd_rebuild
      ;;
    --periodic-sync)
      cmd_periodic_sync
      ;;
    --daily-maintenance)
      cmd_daily_maintenance
      ;;
    --tg-agent-sync)
      return 0
      ;;
    recover)
      cmd_recover
      ;;
    install)
      cmd_install_dispatch "${@:2}"
      ;;
    update)
      cmd_update "${@:2}"
      ;;
    acme)
      cmd_acme_dispatch "${@:2}"
      ;;
    uninstall)
      warn "uninstall 仍是后续里程碑"
      return 1
      ;;
    users)
      cmd_users_dispatch "${@:2}"
      ;;
    protocol|protocols)
      cmd_protocols_dispatch "${@:2}"
      ;;
    export)
      warn "export 仍是后续里程碑"
      return 1
      ;;
    *)
      err "未知命令: ${cmd}"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
