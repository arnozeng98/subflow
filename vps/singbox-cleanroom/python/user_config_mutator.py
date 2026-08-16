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