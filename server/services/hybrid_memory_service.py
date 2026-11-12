"""Canonical versioned memories, migration, ACL and cache invalidation in one place."""
import hashlib
import json
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal
from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator
from services import sync_service, memory_index_service as index
from services.logging_service import get_logger

logger = get_logger("memory")
_loaded = set()
_legacy_signatures = {}
_cache = OrderedDict()
_generation = {}
_warnings = {}


def now():
    return datetime.now(timezone.utc).isoformat()


class Entry(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    content: str = Field(min_length=1, max_length=4000)
    scope: Literal["global", "role", "direct", "group"] = "role"
    owner_id: str = ""
    origin_chat: str = ""
    category: Literal["core", "short_term", "episodic", "knowledge"] = "core"
    kind: Literal["fact", "inference"] = "fact"
    status: Literal["confirmed", "pending", "superseded"] = "confirmed"
    source: str = Field(default="用户手动录入", max_length=500)
    confidence: float = Field(default=1, ge=0, le=1)
    sensitive: bool = False
    shared: bool = False
    fact_key: str = Field(default="", max_length=120)
    conflict_of: str = ""
    conflict_version: str = ""
    created_at: str = Field(default_factory=now)
    updated_at: str = Field(default_factory=now)
    legacy_source: str = Field(default="", max_length=300)
    message_time: str = ''
    message_order: int = 0
    legacy_retired: bool = False
    deleted: bool = False

    @model_validator(mode="after")
    def valid(self):
        if not self.content.strip():
            raise ValueError("empty memory")
        for date in (self.created_at, self.updated_at):
            if datetime.fromisoformat(date).tzinfo is None:
                raise ValueError("timezone required")
        if self.scope == "global":
            if self.owner_id:
                raise ValueError("global owner must be empty")
        else:
            sync_service.identity(self.owner_id)
        if self.origin_chat:
            sync_service.identity(self.origin_chat)
        if self.conflict_of:
            sync_service.identity(self.conflict_of)
        if self.sensitive and not self.origin_chat:
            raise ValueError("private memory requires origin conversation")
        if self.sensitive and self.scope != "global" and self.origin_chat != self.owner_id:
            raise ValueError("private memory origin must match owner")
        return self


def root():
    return Path(sync_service.DATA_DIR)


def profile(folder, key):
    sync_service.identity(key)
    path = root() / folder / key / "profile.json"
    value = json.loads(path.read_text(encoding="utf-8")) if path.exists() else None
    if not value or value.get("deleted"):
        raise HTTPException(404, "角色或群聊不存在")
    return value


def validate(key, payload):
    entry = Entry(**payload)
    if entry.id != key:
        raise HTTPException(422, "记忆编号不匹配")
    if entry.scope != "global":
        profile("groups" if entry.scope == "group" else "roles", entry.owner_id)
    if entry.origin_chat:
        try:
            profile("roles", entry.origin_chat)
        except HTTPException:
            profile("groups", entry.origin_chat)
    return entry.model_dump()


def entries():
    return [json.loads(p.read_text(encoding="utf-8")) for p in (root() / "synced/memory_entry").glob("*.json")]


def invalidate():
    key = str(root())
    _generation[key] = _generation.get(key, 0) + 1
    _cache.clear()


def changed(kind, key, payload):
    if kind == "memory_entry":
        index.project(root(), [payload] if "content" in payload else [{"id": key, "content": "", "deleted": True}])
    if kind in ("memory_entry", "memory_policy", "role", "group", "memory", "user_memory"):
        invalidate()


def ensure_index(rebuild=False):
    key = str(root())
    with sync_service.LOCK:
        if rebuild or key not in _loaded or not (root() / "memory-index.sqlite3").exists():
            with index.database(root()) as db:
                db.execute("DELETE FROM entries")
                db.execute("DELETE FROM search")
                db.execute("DELETE FROM metadata")
            index.project(root(), entries())
            _loaded.add(key)
            invalidate()
        import_legacy()
        # Recover a projection failure after a committed write, without caching stale content.
        with index.database(root()) as db:
            cursor = db.execute("SELECT value FROM metadata WHERE key='cursor'").fetchone()
            cursor = int(cursor[0]) if cursor else 0
        with sync_service.database() as db:
            latest = db.execute("SELECT COALESCE(MAX(seq),0) FROM changes").fetchone()[0]
            rows = db.execute("SELECT DISTINCT e.payload FROM changes c JOIN entities e ON e.kind=c.kind AND e.id=c.id WHERE c.seq>? AND c.kind='memory_entry'", (cursor,)).fetchall()
        if rows:
            index.project(root(), [json.loads(r[0]) for r in rows])
            invalidate()
        with index.database(root()) as db:
            db.execute("INSERT OR REPLACE INTO metadata VALUES ('cursor',?)", (str(latest),))


def policy():
    path = root() / "synced/memory_policy/global.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"share_user_facts": True}


def allowed(entry, role_id, chat_id, permissions=None):
    if entry.get("deleted") or entry["status"] != "confirmed":
        return False
    scope, owner = entry["scope"], entry["owner_id"]
    if entry["sensitive"] and (entry["origin_chat"] != chat_id or (scope in ("role", "direct") and owner != role_id)):
        return False
    if scope == "global":
        shared = permissions[0] if permissions is not None else policy().get("share_user_facts", True)
        return (shared and entry["shared"] and not entry["sensitive"]) or entry["origin_chat"] == chat_id
    if scope in ("role", "direct"):
        # Role memories are private to that role's direct conversation.
        return owner == role_id and chat_id == role_id
    if permissions is not None:
        group = permissions[1].get(owner, {})
    else:
        try:
            group = profile("groups", owner)
        except HTTPException:
            return False
    if role_id not in group.get("member_ids", []):
        return False
    return chat_id == owner or (chat_id == role_id and entry["shared"] and not entry["sensitive"])


def retrieve(role_id, query="", chat_id=None, limit=8):
    start = time.perf_counter()
    chat_id = chat_id or role_id
    profile("roles", role_id)
    if chat_id != role_id and role_id not in profile("groups", chat_id).get("member_ids", []):
        raise HTTPException(403, "角色不是群聊成员")
    with sync_service.LOCK:
        ensure_index()
        # Re-read membership/policy before cache lookup, without rescanning every memory on hits.
        memberships = {}
        for path in (root() / "groups").glob("*/profile.json"):
            group = json.loads(path.read_text(encoding="utf-8"))
            if not group.get("deleted") and role_id in group.get("member_ids", []):
                memberships[path.parent.name] = group
        permissions = (policy().get("share_user_facts", True), memberships)
        acl = hashlib.sha256(sync_service.encode([permissions[0], sorted(memberships)]).encode()).hexdigest()
        key = (str(root()), _generation.get(str(root()), 0), int(time.time() // 60), role_id, chat_id, acl, query[:2000], limit)
        cached = _cache.get(key)
        hit = cached is not None
        if cached:
            result, vector = cached
        else:
            all_entries = entries_from_index()
            permitted = {e["id"] for e in all_entries if allowed(e, role_id, chat_id, permissions)}
            result, vector = index.ranked(root(), permitted, query, limit)
            _cache[key] = (result, vector)
            if len(_cache) > 128:
                _cache.popitem(last=False)
    logger.info("", extra={"event": "memory_retrieved", "count": len(result), "cache_state": "hit" if hit else "miss"})
    return {"entries": result, "cache_hit": hit, "vector_available": vector, "elapsed_ms": round((time.perf_counter() - start) * 1000, 2)}


def entries_from_index():
    with index.database(root()) as db:
        return [json.loads(r[0]) for r in db.execute("SELECT payload FROM entries")]


def context(role_id, query="", chat_id=None):
    result = retrieve(role_id, query, chat_id)
    lines = [f"[{e['category']}; 来源:{e['source']}; 置信度:{e['confidence']:.2f}] {e['content']}" for e in result["entries"]]
    return "以下是获准使用的记忆，仅在相关时自然引用，不提议管理记忆或暴露程序设定；推测不能当作事实：\n" + "\n".join(lines) if lines else ""


def save(payload, base_version=None, operation_id=None):
    key = payload["id"]
    result = sync_service.mutate({"kind": "memory_entry", "id": key, "payload": payload,
                                  "base_version": base_version, "operation_id": operation_id or uuid.uuid4().hex})
    return result


def prepare(payload, previous=None, db=None):
    value = Entry(**payload).model_dump()
    if previous:
        for field in ("id", "created_at", "legacy_source"):
            value[field] = previous[field]
    value["updated_at"] = now()
    validate(value["id"], value)
    # A structured fact key makes contradictory values explicit, never overwriting another entry.
    if value["fact_key"]:
        for other in entries():
            if (other.get("id") != value["id"] and not other.get("deleted") and other.get("status") == "confirmed"
                    and (other.get("scope"), other.get("owner_id"), other.get("fact_key")) == (value["scope"], value["owner_id"], value["fact_key"])
                    and other["content"] != value["content"]):
                version = db.execute("SELECT version FROM entities WHERE kind='memory_entry' AND id=?", (other["id"],)).fetchone()[0] if db is not None else sync_service.version("memory_entry", other["id"])
                value.update(status="pending", conflict_of=other["id"], conflict_version=version)
                break
    if value["kind"] == "inference" and not previous:
        value["status"] = "pending"
    return value


def confirm(key, expected, operation_id):
    """Resolve both versions in one journaled transaction; retries return original receipt."""
    sync_service.identity(key)
    with sync_service.LOCK:
        sync_service.recover_pending()
        sync_service.reconcile()
        fingerprint = hashlib.sha256(sync_service.encode(["confirm_memory", key, expected]).encode()).hexdigest()
        with sync_service.database() as db:
            receipt = db.execute("SELECT * FROM receipts WHERE id=?", (operation_id,)).fetchone()
            if receipt:
                if receipt["fingerprint"] != fingerprint:
                    raise HTTPException(409, "操作编号已用于其他内容")
                return json.loads(receipt["result"])
            row = db.execute("SELECT * FROM entities WHERE kind='memory_entry' AND id=?", (key,)).fetchone()
            if not row or row["deleted"] or row["version"] != expected:
                raise HTTPException(409, "记忆已被修改或删除，请重新载入")
            value = json.loads(row["payload"])
            if value["status"] != "pending":
                raise HTTPException(409, "此记忆不处于待验证状态")
            values = []
            if value["conflict_of"]:
                old = db.execute("SELECT * FROM entities WHERE kind='memory_entry' AND id=?", (value["conflict_of"],)).fetchone()
                if not old or old["deleted"] or old["version"] != value["conflict_version"]:
                    raise HTTPException(409, "冲突事实已经变化，请重新检查两条记忆")
                previous = json.loads(old["payload"])
                previous.update(status="superseded", updated_at=now())
                values.append(previous)
            value.update(status="confirmed", updated_at=now(), conflict_of="", conflict_version="")
            values.append(value)
            entities = [sync_service.unpack(sync_service.record(db, "memory_entry", v["id"], v)) for v in values]
            result = {"status": "applied", "entity": entities[-1]}
            intent = root() / "sync-pending" / (hashlib.sha256(operation_id.encode()).hexdigest() + ".json")
            sync_service.write_json(intent, {"batch": entities, "operation_id": operation_id,
                                           "fingerprint": fingerprint, "result": result})
            for entry in entities:
                sync_service.write_json(sync_service.entity_path("memory_entry", entry["id"]), entry["payload"])
            db.execute("INSERT INTO receipts VALUES (?,?,?)", (operation_id, fingerprint, sync_service.encode(result)))
        completed = root() / "sync-completed" / intent.name
        completed.parent.mkdir(parents=True, exist_ok=True)
        intent.rename(completed)
        index.project(root(), values)
        invalidate()
        return result


def propose(role_id, content, source, group_id=None):
    value = Entry(id=uuid.uuid4().hex, content=content[:4000], scope="group" if group_id else "direct",
                  owner_id=group_id or role_id, origin_chat=group_id or role_id, category="episodic",
                  kind="inference", status="pending", source=source, confidence=0.5).model_dump()
    return save(value)


def import_legacy():
    """Idempotent deterministic import; old files retained, tombstones never resurrect."""
    paths = list((root() / "roles").glob("*/profile.json")) + list((root() / "roles").glob("*/memory.json"))
    paths += list((root() / "groups").glob("*/profile.json")) + list((root() / "groups").glob("*/memory.json"))
    paths += list((root() / "synced/user_memory").glob("global.json"))
    for path in paths:
        relative = path.relative_to(root()).as_posix()
        signature = (path.stat().st_mtime_ns, path.stat().st_size)
        cache_key = (str(root()), relative)
        if _legacy_signatures.get(cache_key) == signature:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("deleted"):
                continue
            scope = "global" if relative.startswith("synced/") else "group" if relative.startswith("groups/") else "direct" if path.name == "memory.json" else "role"
            owner = "" if scope == "global" else path.parent.name
            if owner:
                profile("groups" if scope == "group" else "roles", owner)
            core = data.get("core_memory", [])
            core = [core] if isinstance(core, str) else core
            rows = [("core", c, "用户既有核心记忆", "fact", "confirmed", None) for c in core if isinstance(c, str) and c.strip()]
            occurrences = {}
            for position, short in enumerate(data.get("short_term", [])):
                text = short if isinstance(short, str) else short.get("content", "")
                if text.strip():
                    speaker = short.get("role", "user") if isinstance(short, dict) else "user"
                    original = short if isinstance(short, dict) else {}
                    moment = original.get('timestamp') or '1970-01-01T00:00:00+00:00'
                    parsed = datetime.fromisoformat(moment)
                    moment = parsed.replace(tzinfo=timezone.utc).isoformat() if parsed.tzinfo is None else parsed.astimezone(timezone.utc).isoformat()
                    message_signature = sync_service.encode([speaker, text, moment])
                    occurrence = occurrences.get(message_signature, 0)
                    occurrences[message_signature] = occurrence + 1
                    message_id = original.get('id') or [message_signature, occurrence]
                    rows.append(("short_term", text, "旧会话:" + speaker, "fact", "confirmed",
                                 {'identity': message_id, 'message_time': moment, 'message_order': position}))
            if data.get("summary"):
                rows.append(("episodic", data["summary"], "旧群聊自动总结", "inference", "pending", None))
            wanted = set()
            for category, content, source, kind, status, message_info in rows:
                # Duplicate legacy core fields represent one fact, not two resurrectable copies.
                domain = "role" if scope in ("role", "direct") else scope
                fields = [domain, owner, category, content] if message_info is None else [scope, owner, category, message_info['identity']]
                identity = "legacy_" + hashlib.sha256(sync_service.encode(fields).encode()).hexdigest()[:40]
                wanted.add(identity)
                dest = root() / "synced/memory_entry" / (identity + ".json")
                if dest.exists():
                    existing = json.loads(dest.read_text(encoding='utf-8'))
                    if message_info and existing.get('message_order') != message_info['message_order']:
                        existing['message_order'] = message_info['message_order']
                        sync_service.write_json(dest, existing)
                        with sync_service.database() as db:
                            sync_service.record(db, 'memory_entry', identity, existing, existing.get('deleted', False))
                        changed('memory_entry', identity, existing)
                    continue
                # Preserve edits/deletions made to the old content-based projection.
                old_id = 'legacy_' + hashlib.sha256(sync_service.encode([domain, owner, category, content]).encode()).hexdigest()[:40]
                old_path = root() / 'synced/memory_entry' / (old_id + '.json')
                previous = json.loads(old_path.read_text(encoding='utf-8')) if message_info and old_path.exists() else None
                overrides = {k: previous[k] for k in ('content', 'sensitive', 'shared', 'deleted', 'status') if k in previous} if previous and not previous.get('legacy_retired') else {}
                entry = Entry(id=identity, content=content[:4000], scope=scope, owner_id=owner,
                              origin_chat=owner, category=category, source=source, kind=kind, status=status,
                              shared=scope == "global", legacy_source=relative,
                              message_time=message_info['message_time'] if message_info else '',
                              message_order=message_info['message_order'] if message_info else 0).model_dump()
                entry.update(overrides)
                # Migration uses the same durable entity/changes transaction, but does not recursively reconcile.
                sync_service.write_json(dest, entry)
                with sync_service.database() as db:
                    sync_service.record(db, "memory_entry", identity, entry)
                changed("memory_entry", identity, entry)
            for entry in entries():
                if entry.get("legacy_source") == relative and entry["id"] not in wanted and not entry.get("deleted"):
                    entry.update(deleted=True, legacy_retired=True, updated_at=now())
                    sync_service.write_json(root() / "synced/memory_entry" / (entry["id"] + ".json"), entry)
                    with sync_service.database() as db:
                        sync_service.record(db, "memory_entry", entry["id"], entry, True)
                    changed("memory_entry", entry["id"], entry)
            _legacy_signatures[cache_key] = signature
        except (ValueError, TypeError, AttributeError, HTTPException):
            _warnings[(str(root()), relative)] = {"path": relative, "reason": "无法可靠转换，原始文件和保护备份保留"}
            logger.warning("", extra={"event": "legacy_memory_retained_unconverted"})


def migrate():
    report_path = root() / "migration-memory-v6.json"
    if not report_path.exists():
        from services import backup_service
        backup = backup_service.create(internal=True)
        ensure_index()
        sync_service.write_json(report_path, {"schema_version": 6, "backup_id": backup["id"], "originals_retained": True,
                                              "entries": len(entries()), "created_at": now(),
                                              "warnings": [v for (r, _), v in _warnings.items() if r == str(root())]})
    else:
        ensure_index()
