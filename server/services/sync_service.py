"""Versioned business entities and a bounded change feed; histories stay indexed."""
import hashlib
import copy
import json
import re
import sqlite3
import threading
import uuid
from functools import wraps
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import HTTPException
from services.paths_service import DATA_DIR, CONFIG_DIR
from services.logging_service import get_logger

logger = get_logger("sync")
LOCK = threading.RLock()


def local_commit(function):
    """Serialize a synchronous read/modify/write, never a provider wait."""
    @wraps(function)
    def wrapped(*args, **kwargs):
        with LOCK:
            return function(*args, **kwargs)
    return wrapped


def local_mutation(function):
    """Short legacy commit boundary; only for handlers without awaited I/O."""
    @wraps(function)
    async def wrapped(*args, **kwargs):
        with LOCK:
            return await function(*args, **kwargs)
    return wrapped
KINDS = {"role", "group", "memory", "favorite", "preferences", "user_memory", "settings", "memory_entry", "memory_policy",
         "behavior_policy", "behavior_config", "behavior_state", "tts_policy", "tts_config"}
PREFERENCE_KEYS = {"user_nickname", "user_avatar_url", "cover_image_url", "chat_background_url"}
SECRET = re.compile(r"(api.?key|token|password|secret|credential|authorization)", re.I)


def public(value):
    if isinstance(value, dict):
        return {k: public(v) for k, v in value.items() if not SECRET.search(k)}
    if isinstance(value, list):
        return [public(v) for v in value]
    return value


def identity(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value):
        raise HTTPException(422, "无效数据编号")
    from tools.data_protection import safe_child
    try:
        safe_child(DATA_DIR / "identity-validation", value)
    except ValueError:
        raise HTTPException(422, "数据编号不能使用保留文件名")
    return value


def encode(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".pending-" + uuid.uuid4().hex)
    with temporary.open("x", encoding="utf-8") as stream:
        stream.write(encode(value))
        stream.flush()
        import os
        os.fsync(stream.fileno())
    temporary.replace(path)


@contextmanager
def database(root=None):
    root = Path(root or DATA_DIR)
    root.mkdir(parents=True, exist_ok=True)
    with LOCK:
        db = sqlite3.connect(root / "sync.sqlite3", timeout=30)
        db.row_factory = sqlite3.Row
        try:
            with db:
                db.executescript("""
                  CREATE TABLE IF NOT EXISTS entities(kind TEXT,id TEXT,version TEXT,payload TEXT,
                    deleted INTEGER DEFAULT 0,PRIMARY KEY(kind,id));
                  CREATE TABLE IF NOT EXISTS changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT,id TEXT,version TEXT,payload TEXT,deleted INTEGER);
                  CREATE TABLE IF NOT EXISTS versions(kind TEXT,id TEXT,version TEXT,payload TEXT,
                    deleted INTEGER,PRIMARY KEY(kind,id,version));
                  CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY,fingerprint TEXT,result TEXT);
                  CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT);
                """)
                db.execute("INSERT OR IGNORE INTO meta VALUES ('epoch',?)", (uuid.uuid4().hex,))
                yield db
        finally:
            db.close()


def record(db, kind, key, payload, deleted=False):
    text = encode(public(payload))
    old = db.execute("SELECT * FROM entities WHERE kind=? AND id=?", (kind, key)).fetchone()
    if old and old["payload"] == text and bool(old["deleted"]) == deleted:
        return dict(old)
    version = uuid.uuid4().hex
    values = (kind, key, version, text, int(deleted))
    db.execute("INSERT OR REPLACE INTO entities VALUES (?,?,?,?,?)", values)
    db.execute("INSERT INTO changes(kind,id,version,payload,deleted) VALUES (?,?,?,?,?)", values)
    db.execute("INSERT INTO versions VALUES (?,?,?,?,?)", values)
    return dict(kind=kind, id=key, version=version, payload=text, deleted=int(deleted))


def unpack(row):
    return {**dict(row), "payload": json.loads(row["payload"]), "deleted": bool(row["deleted"])}


def entity_path(kind, key, root=None):
    root = Path(root or DATA_DIR)
    identity(key)
    if kind in ("role", "group", "memory"):
        return root / ("groups" if kind == "group" else "roles") / key / ("memory.json" if kind == "memory" else "profile.json")
    if kind == "settings":
        return CONFIG_DIR / "settings.json"
    if kind == "behavior_state":
        return root / "roles" / key / "life.json"
    if kind in ("favorite", "preferences", "user_memory", "memory_entry", "memory_policy", "behavior_policy", "behavior_config", "tts_policy", "tts_config"):
        return root / "synced" / kind / (key + ".json")
    raise HTTPException(422, "不支持的数据类型")


def reconcile(root=None, config=None):
    """Discover writes from scheduler/legacy routes without ever reading full histories."""
    root, config = Path(root or DATA_DIR), Path(config or CONFIG_DIR)
    paths = []
    for folder, kind in (("roles", "role"), ("groups", "group")):
        for p in sorted((root / folder).glob("*/profile.json")):
            paths.append((kind, p.parent.name, p))
        if kind == "role":
            paths.extend(("memory", p.parent.name, p) for p in sorted((root / folder).glob("*/memory.json")))
            paths.extend(("behavior_state", p.parent.name, p) for p in sorted((root / folder).glob("*/life.json")))
    for kind in ("favorite", "preferences", "user_memory", "memory_entry", "memory_policy", "behavior_policy", "behavior_config", "tts_policy", "tts_config"):
        paths.extend((kind, p.stem, p) for p in sorted((root / "synced" / kind).glob("*.json")))
    if (config / "settings.json").exists():
        paths.append(("settings", "global", config / "settings.json"))
    warnings = []
    with database(root) as db:
        for kind, key, path in paths:
            try:
                identity(key)
                payload = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(payload, dict):
                    raise ValueError("Expected object")
                if kind in ("role", "group") and payload.get("id") != key:
                    raise ValueError("Mismatched identity")
                if kind == "settings":
                    payload = {k: v for k, v in public(payload).items() if k not in ("host", "port", "updated_at")}
                payload.pop("sync_version", None)
                record(db, kind, key, payload, bool(payload.get("deleted")))
            except (ValueError, TypeError, HTTPException, OSError):
                warnings.append({"kind": kind, "id": key, "reason": "无法可靠识别，原文件保留"})
    return warnings


def version(kind, key, root=None, payload=None):
    with database(root) as db:
        if payload is not None:
            payload = {k: v for k, v in payload.items() if k != "sync_version"}
            record(db, kind, key, payload)
        row = db.execute("SELECT version FROM entities WHERE kind=? AND id=?", (kind, key)).fetchone()
        return row[0] if row else None


def check_version(kind, key, expected, root=None, payload=None):
    current = version(kind, key, root, payload)
    if current != expected:
        raise HTTPException(409, {"code": "version_conflict", "kind": kind, "id": key,
                                  "version": current, "message": "数据已在其他设备修改，请在数据同步页处理冲突"})


def feed(after=0, epoch=None, limit=100):
    if after < 0 or not 1 <= limit <= 200:
        raise HTTPException(422, "无效同步游标")
    recover_pending()
    reconcile()
    with database() as db:
        current = db.execute("SELECT value FROM meta WHERE key='epoch'").fetchone()[0]
        reset = epoch != current
        if reset:
            after = 0
        rows = db.execute("SELECT * FROM changes WHERE seq>? ORDER BY seq LIMIT ?", (after, limit + 1)).fetchall()
        selected = rows[:limit]
        return {"schema_version": 4, "epoch": current, "reset": reset,
                "changes": [unpack(r) for r in selected], "has_more": len(rows) > limit,
                "cursor": selected[-1]["seq"] if selected else after}


def validate_payload(kind, key, payload):
    if kind not in KINDS or kind == "settings":
        raise HTTPException(422, "此类型请使用专用设置接口")
    if public(payload) != payload:
        raise HTTPException(422, "同步内容不能包含访问凭证")
    if kind.startswith("tts_"):
        from services.tts_service import validate
        payload.update(validate(kind, key, payload))
    if kind.startswith("behavior_"):
        from services.behavior_service import validate
        payload.update(validate(kind, key, payload))
    if kind == "memory_entry":
        from services import hybrid_memory_service as memory
        payload.update(memory.validate(key, payload))
    if kind == "memory_policy" and (key != "global" or set(payload) != {"share_user_facts"}
                                     or type(payload.get("share_user_facts")) is not bool):
        raise HTTPException(422, "记忆共享设置无效")
    if kind == "role":
        from routers.roles import RoleCreate
        role = RoleCreate(**payload)
        config = payload.get("proactive_config") or {}
        payload.update(role.model_dump(exclude_none=True))
        if "min_countdown_hours" in config:
            config["min_interval_minutes"] = round(config.pop("min_countdown_hours") * 60)
        if "max_countdown_hours" in config:
            config["max_interval_minutes"] = round(config.pop("max_countdown_hours") * 60)
        payload["proactive_config"] = {**role.proactive_config.model_dump(), **config} if role.proactive_config else config
    if kind == "group":
        from routers.groups import Group
        payload.update(Group(**payload).model_dump())
        if not payload.get("member_ids"):
            raise HTTPException(422, "群聊必须包含成员")
        for member in payload["member_ids"]:
            identity(member)
            profile = DATA_DIR / "roles" / member / "profile.json"
            if not profile.exists() or json.loads(profile.read_text(encoding="utf-8")).get("deleted"):
                raise HTTPException(422, "群聊成员不存在")
    if kind in ("role", "group") and payload.get("id") != key:
        raise HTTPException(422, "数据编号不匹配")
    if kind == "memory":
        profile = DATA_DIR / "roles" / key / "profile.json"
        if not profile.exists() or json.loads(profile.read_text(encoding="utf-8")).get("deleted"):
            raise HTTPException(404, "目标角色不存在")
        if not isinstance(payload.get("core_memory", ""), (str, list)):
            raise HTTPException(422, "核心记忆格式无效")
        if isinstance(payload.get("core_memory"), list) and not all(isinstance(x, str) for x in payload["core_memory"]):
            raise HTTPException(422, "核心记忆格式无效")
        if not isinstance(payload.get("short_term", []), list) or not all(
            isinstance(x, str) or (isinstance(x, dict) and isinstance(x.get("role"), str) and isinstance(x.get("content"), str))
            for x in payload.get("short_term", [])
        ):
            raise HTTPException(422, "短期记忆格式无效")
    if kind in ("preferences", "user_memory") and key != "global":
        raise HTTPException(422, "无效全局数据编号")
    if kind == "preferences" and set(payload) - PREFERENCE_KEYS:
        raise HTTPException(422, "不支持的同步设置")
    if kind == "preferences" and not all(isinstance(value, str) for value in payload.values()):
        raise HTTPException(422, "显示设置格式无效")
    if kind == "user_memory" and (set(payload) != {"core_memory"} or not isinstance(payload["core_memory"], list)
                                  or not all(isinstance(x, str) for x in payload["core_memory"])):
        raise HTTPException(422, "用户记忆格式无效")
    if kind == "favorite":
        required = ("id", "chat_id", "chat_name", "user_name", "role_name", "created_at")
        if payload.get("id") != key or not all(isinstance(payload.get(field), str) for field in required) or not isinstance(payload.get("messages"), list):
            raise HTTPException(422, "收藏格式无效")
        from services.history_service import timestamp
        try:
            timestamp(payload["created_at"])
            if not isinstance(payload.get("tags", []), list) or not all(isinstance(tag, str) for tag in payload.get("tags", [])):
                raise ValueError()
            for message in payload["messages"]:
                if not isinstance(message, dict) or not all(isinstance(message.get(field), str) for field in ("id", "sender_id", "sender_name", "content", "timestamp")):
                    raise ValueError()
                timestamp(message["timestamp"])
                if not isinstance(message.get("is_from_user", False), bool) or (message.get("quoted_content") is not None and not isinstance(message["quoted_content"], str)):
                    raise ValueError()
        except (ValueError, TypeError):
            raise HTTPException(422, "收藏消息格式无效")


def mutate(operation, receipt_metadata=None):
    operation = copy.deepcopy(operation)
    kind, key = operation["kind"], identity(operation["id"])
    payload, deleted = operation.get("payload", {}), operation.get("deleted", False)
    if kind not in KINDS or kind == "settings":
        raise HTTPException(422, "不支持的同步类型")
    if kind == "behavior_state" or ((kind.startswith("behavior_") or kind.startswith("tts_")) and deleted):
        raise HTTPException(422, "行为设置请用开关停用；生活状态不能由客户端覆盖")
    if len(encode(payload).encode()) > 2 * 1024 * 1024:
        raise HTTPException(413, "单项同步内容超过 2 MiB")
    fingerprint = hashlib.sha256(encode(operation).encode()).hexdigest()
    original_operation = copy.deepcopy(operation)
    validate_payload(kind, key, payload) if not deleted else None
    recover_pending()
    reconcile()
    with database() as db:
        receipt = db.execute("SELECT * FROM receipts WHERE id=?", (operation["operation_id"],)).fetchone()
        if receipt:
            if receipt["fingerprint"] != fingerprint:
                raise HTTPException(409, "操作编号已用于其他内容")
            return json.loads(receipt["result"])
        old = db.execute("SELECT * FROM entities WHERE kind=? AND id=?", (kind, key)).fetchone()
        if kind != "preferences" and (old["version"] if old else None) != operation.get("base_version"):
            return {"status": "conflict", "current": unpack(old) if old else None, "proposed": operation}
        if not deleted and kind in ("role", "group"):
            payload.setdefault("schema_version", 4)
        if deleted and kind in ("role", "group"):
            # Logical deletion keeps every file available for recovery.
            payload = {**(json.loads(old["payload"]) if old else {}), "deleted": True}
        elif deleted and kind == "memory_entry":
            payload = {**(json.loads(old["payload"]) if old else {}), "deleted": True}
        elif deleted:
            payload = {"deleted": True}
        if kind == "memory_entry" and not deleted:
            from services import hybrid_memory_service as memory
            previous = json.loads(old["payload"]) if old and not old["deleted"] else None
            if old and old["deleted"]:
                raise HTTPException(409, "已删除记忆不能通过同步复活，请新建条目")
            payload = memory.prepare(payload, previous, db)
        if not deleted and kind in ("role", "group", "memory", "preferences") and old and not old["deleted"]:
            # Keep server-only metadata, such as the uploaded avatar filename.
            previous = json.loads(old["payload"])
            if kind == "role":
                payload["metadata"] = {**(previous.get("metadata") or {}), **(payload.get("metadata") or {})}
            payload = {**previous, **payload}
        path = entity_path(kind, key)
        # Save an intent before projecting to JSON. A crash after the rename but
        # before the SQLite commit can then be replayed with its original ID.
        intent = DATA_DIR / "sync-pending" / (hashlib.sha256(operation["operation_id"].encode()).hexdigest() + ".json")
        row = record(db, kind, key, payload, deleted)
        result = {"status": "applied", "entity": unpack(row), **(receipt_metadata or {})}
        write_json(intent, {"operation": original_operation, "fingerprint": fingerprint, "result": result})
        write_json(path, payload)
        db.execute("INSERT INTO receipts VALUES (?,?,?)", (operation["operation_id"], fingerprint, encode(result)))
    completed = DATA_DIR / "sync-completed" / intent.name
    completed.parent.mkdir(parents=True, exist_ok=True)
    intent.rename(completed)
    if kind == "role":
        from services.scheduler_service import schedule_proactive_for_role
        schedule_proactive_for_role(key)
    from services import hybrid_memory_service
    hybrid_memory_service.changed(kind, key, payload)
    logger.info("", extra={"event": "entity_synced", "count": 1})
    return result


def recover_pending():
    for path in (DATA_DIR / "sync-pending").glob("*.json"):
        data = json.loads(path.read_text(encoding="utf-8"))
        if "batch" in data:
            with database() as db:
                if not db.execute("SELECT 1 FROM receipts WHERE id=?", (data["operation_id"],)).fetchone():
                    for row in data["batch"]:
                        write_json(entity_path(row["kind"], row["id"]), row["payload"])
                        values = (row["kind"], row["id"], row["version"], encode(row["payload"]), int(row["deleted"]))
                        db.execute("INSERT OR REPLACE INTO entities VALUES (?,?,?,?,?)", values)
                        db.execute("INSERT OR IGNORE INTO versions VALUES (?,?,?,?,?)", values)
                        db.execute("INSERT INTO changes(kind,id,version,payload,deleted) VALUES (?,?,?,?,?)", values)
                    db.execute("INSERT INTO receipts VALUES (?,?,?)", (data["operation_id"], data["fingerprint"], encode(data["result"])))
            from services import hybrid_memory_service
            for row in data["batch"]:
                hybrid_memory_service.changed(row["kind"], row["id"], row["payload"])
            completed = DATA_DIR / "sync-completed" / path.name
            completed.parent.mkdir(parents=True, exist_ok=True)
            path.rename(completed)
            continue
        op, result = data["operation"], data["result"]
        with database() as db:
            if db.execute("SELECT 1 FROM receipts WHERE id=?", (op["operation_id"],)).fetchone():
                completed = DATA_DIR / "sync-completed" / path.name
                completed.parent.mkdir(parents=True, exist_ok=True)
                path.rename(completed)
                continue
            row = result["entity"]
            write_json(entity_path(row["kind"], row["id"]), row["payload"])
            values = (row["kind"], row["id"], row["version"], encode(row["payload"]), int(row["deleted"]))
            db.execute("INSERT OR REPLACE INTO entities VALUES (?,?,?,?,?)", values)
            db.execute("INSERT OR IGNORE INTO versions VALUES (?,?,?,?,?)", values)
            db.execute("INSERT INTO changes(kind,id,version,payload,deleted) VALUES (?,?,?,?,?)", values)
            db.execute("INSERT INTO receipts VALUES (?,?,?)", (op["operation_id"], data["fingerprint"], encode(result)))
        from services import hybrid_memory_service
        hybrid_memory_service.changed(row["kind"], row["id"], row["payload"])
        completed = DATA_DIR / "sync-completed" / path.name
        completed.parent.mkdir(parents=True, exist_ok=True)
        path.rename(completed)


def migration_report():
    path = DATA_DIR / "migration-v4.json"
    report = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"schema_version": 4, "status": "pending"}
    role_api = DATA_DIR / "migration-role-api-v5.json"
    if role_api.exists():
        report["role_api_v5"] = json.loads(role_api.read_text(encoding="utf-8"))
    memory = DATA_DIR / "migration-memory-v6.json"
    if memory.exists():
        report["memory_v6"] = json.loads(memory.read_text(encoding="utf-8"))
    credentials = DATA_DIR / 'migration-provider-origin-v9.json'
    if credentials.exists():
        report['credentials_v9'] = json.loads(credentials.read_text(encoding='utf-8'))
    return report


def migrate():
    path = DATA_DIR / "migration-v4.json"
    if path.exists():
        return migration_report()
    from services import backup_service, history_service
    backup = backup_service.create(internal=True)
    warnings = reconcile()
    histories = 0
    for folder in ("roles", "groups"):
        for profile in (DATA_DIR / folder).glob("*/profile.json"):
            try:
                history_service.page(profile.parent / "chats", limit=1)
                histories += 1
            except (ValueError, OSError, sqlite3.Error):
                warnings.append({"kind": "history", "id": profile.parent.name, "reason": "旧记录无法可靠转换，原始文件及备份保留"})
    report = {"schema_version": 4, "status": "complete_with_warnings" if warnings else "complete",
              "created_at": datetime.now(timezone.utc).isoformat(), "backup_id": backup["id"],
              "histories": histories, "warnings": warnings, "originals_retained": True}
    write_json(path, report)
    get_logger("migration").info("", extra={"event": "data_migrated", "count": histories})
    return report
