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