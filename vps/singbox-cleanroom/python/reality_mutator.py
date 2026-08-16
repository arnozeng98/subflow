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