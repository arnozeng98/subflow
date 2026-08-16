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