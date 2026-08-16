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