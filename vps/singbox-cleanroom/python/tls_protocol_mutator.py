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