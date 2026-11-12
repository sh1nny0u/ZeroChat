"""Verified portable backups and retained-directory restore, never destructive cleanup."""
import hashlib
from contextlib import closing
import json
import os
import sqlite3
import shutil
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import HTTPException
from services.paths_service import DATA_DIR, CONFIG_DIR, RUNTIME_DIR
from services import sync_service
from tools.data_protection import private_directory, safe_child
from services.logging_service import get_logger

MAX_BYTES = 256 * 1024 * 1024
MAX_FILES = 20000


def allowed_data_file(relative):
    parts = Path(relative).parts
    if not parts or parts[0] not in {"roles", "groups", "moments", "tasks", "avatars", "images", "audio", "synced",
                                        "operations.sqlite3", "sync.sqlite3", "migration-v4.json", "migration-role-api-v5.json", "migration-memory-v6.json", "migration-provider-origin-v9.json"}:
        return False
    if any(sync_service.SECRET.search(p) for p in parts):
        return False
    return Path(relative).suffix.lower() in {".json", ".sqlite3", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".mp3", ".wav", ".m4a", ".ogg"}


def directory():
    root = Path(os.environ.get("ZEROCHAT_BACKUP_DIR", str(RUNTIME_DIR / "backups"))).resolve()
    if root == DATA_DIR.resolve() or root.is_relative_to(DATA_DIR.resolve()) or root == CONFIG_DIR.resolve() or root.is_relative_to(CONFIG_DIR.resolve()):
        raise HTTPException(500, "备份目录须位于业务数据和配置目录之外")
    return private_directory(root)


def archive_path(key):
    sync_service.identity(key)
    return directory() / (key + ".zip")


def _sqlite_bytes(path):
    source = sqlite3.connect(path)
    target = sqlite3.connect(":memory:")
    try:
        source.backup(target)
        if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Database integrity check failed")
        return target.serialize()
    finally:
        source.close()
        target.close()


def create(internal=False):
    key = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex
    path = archive_path(key)
    candidates = [p for p in DATA_DIR.rglob('*') if p.is_file() and (internal or allowed_data_file(p.relative_to(DATA_DIR)))] if DATA_DIR.exists() else []
    estimated = sum(p.stat().st_size for p in candidates)
    if estimated > MAX_BYTES or len(candidates) >= MAX_FILES:
        raise HTTPException(413, '备份超过 256 MiB / 20000 文件限制，请先手动归档；原数据保留')
    if shutil.disk_usage(path.parent).free < estimated * 2 + 16 * 1024 * 1024:
        raise HTTPException(507, '备份磁盘空间不足，请手动释放空间或更换备份目录；原数据保留')
    entries, total, excluded = [], 0, []
    with sync_service.LOCK, zipfile.ZipFile(path, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        if DATA_DIR.exists():
            for source in sorted(DATA_DIR.rglob("*")):
                if source.is_symlink() or (hasattr(source, "is_junction") and source.is_junction()):
                    raise HTTPException(422, "备份来源含链接，已停止")
                if not source.is_file():
                    continue
                relative = source.relative_to(DATA_DIR).as_posix()
                if source.name.endswith(("-wal", "-shm", "-journal")) or ".pending-" in source.name or relative.startswith(("sync-pending/", "sync-completed/")):
                    continue
                if not internal and not allowed_data_file(relative):
                    excluded.append(relative)
                    continue
                if source.suffix == ".sqlite3":
                    if source.name not in ("messages.sqlite3", "operations.sqlite3", "sync.sqlite3"):
                        continue
                    content = _sqlite_bytes(source)
                else:
                    content = source.read_bytes()
                    if not internal and source.suffix == ".json":
                        try:
                            content = sync_service.encode(sync_service.public(json.loads(content))).encode()
                        except (ValueError, UnicodeDecodeError):
                            # Unrecognizable legacy input remains in protected internal snapshots.
                            excluded.append(relative)
                            continue
                total += len(content)
                if total > MAX_BYTES or len(entries) >= MAX_FILES:
                    raise HTTPException(413, "备份超过当前 256 MiB / 20000 文件限制")
                name = "data/" + relative
                archive.writestr(name, content)
                entries.append({"path": name, "size": len(content), "sha256": hashlib.sha256(content).hexdigest()})
        from services.settings_service import load_settings
        settings = load_settings()
        if not internal:
            settings = sync_service.public(settings)
        content = sync_service.encode(settings).encode()
        archive.writestr("settings.json", content)
        entries.append({"path": "settings.json", "size": len(content), "sha256": hashlib.sha256(content).hexdigest()})
        manifest = {"format": "zerochat-backup", "schema_version": 4, "id": key,
                    "created_at": datetime.now(timezone.utc).isoformat(), "internal": internal,
                    "contains_credentials": internal, "files": entries,
                    "excluded": ["administrator", "sessions", "runtime_logs", "sync_pending"],
                    "unrecognized_files": excluded}
        archive.writestr("manifest.json", sync_service.encode(manifest))
    verify(path, allow_internal=internal)
    sync_service.write_json(path.with_suffix('.verified.json'), {"size": path.stat().st_size})
    get_logger("migration").info("", extra={"event": "backup_verified", "count": len(entries)})
    return {k: v for k, v in manifest.items() if k != "files"} | {"size": path.stat().st_size, "files": len(entries)}


def verify(path, allow_internal=False):
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_FILES + 2 or sum(i.file_size for i in infos) > MAX_BYTES:
            raise ValueError("Backup exceeds limits")
        if any(i.flag_bits & 1 or (i.external_attr >> 16) & 0o170000 == 0o120000 for i in infos):
            raise ValueError("Encrypted entries and links are not supported")
        names = [i.filename for i in infos]
        if len(names) != len(set(n.casefold() for n in names)):
            raise ValueError("Duplicate archive path")
        for name in names:
            safe_child(directory() / "validation-only", name)
        manifest = json.loads(archive.read("manifest.json"))
        if manifest.get("format") != "zerochat-backup" or manifest.get("schema_version") != 4 or (manifest.get("internal") and not allow_internal):
            raise ValueError("Unsupported backup")
        listed = [e["path"] for e in manifest["files"]]
        if len(set(listed)) != len(listed) or set(names) != set(listed) | {"manifest.json"}:
            raise ValueError("Unlisted or missing archive members")
        for entry in manifest["files"]:
            name = entry["path"]
            if name != "settings.json" and not name.startswith("data/"):
                raise ValueError("Invalid backup scope")
            if any(sync_service.SECRET.search(p) for p in Path(name).parts):
                raise ValueError("Authentication/credential files cannot be restored")
            if name.startswith("data/") and not manifest.get("internal") and not allowed_data_file(name[5:]):
                raise ValueError("Unsupported business data file")
            content = archive.read(name)
            if len(content) != entry["size"] or hashlib.sha256(content).hexdigest() != entry["sha256"]:
                raise ValueError("Backup checksum mismatch")
            if not manifest.get("internal") and name.endswith(".json"):
                data = json.loads(content)
                if sync_service.public(data) != data:
                    raise ValueError("Portable backup contains credentials")
        return manifest


def list_backups():
    result = []
    for path in sorted(directory().glob("*.zip"), reverse=True):
        try:
            with zipfile.ZipFile(path) as z:
                m = json.loads(z.read("manifest.json"))
            if m.get("format") == "zerochat-backup" and not m.get("internal") and path.with_suffix('.verified.json').exists():
                result.append({"id": path.stem, "created_at": m["created_at"], "size": path.stat().st_size})
        except (ValueError, KeyError, zipfile.BadZipFile):
            continue
    return result


def import_backup(content):
    if len(content) > MAX_BYTES:
        raise HTTPException(413, "备份文件过大")
    key = "uploaded-" + uuid.uuid4().hex
    path = archive_path(key)
    with path.open("xb") as stream:
        stream.write(content)
    try:
        manifest = verify(path)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile):
        raise HTTPException(422, "备份校验失败，原数据未改动")
    sync_service.write_json(path.with_suffix('.verified.json'), {"size": path.stat().st_size})
    return {"id": key, "created_at": manifest["created_at"], "scope": "角色、聊天、群聊、收藏、记忆、素材及普通设置；账号和供应商密钥保留"}


def recover_interrupted():
    journal = RUNTIME_DIR / "restore-state/restore-pending.json"
    if not journal.exists():
        return
    data = json.loads(journal.read_text(encoding="utf-8"))
    retained = Path(data["retained"])
    if retained.parent != DATA_DIR.parent.resolve() or not retained.name.startswith(DATA_DIR.name + ".retained-"):
        raise RuntimeError("Invalid restore recovery path")
    if retained.exists():
        if DATA_DIR.exists():
            DATA_DIR.rename(DATA_DIR.with_name(DATA_DIR.name + ".interrupted-" + uuid.uuid4().hex))
        retained.rename(DATA_DIR)
    if "settings" in data:
        sync_service.write_json(CONFIG_DIR / "settings.json", data["settings"])
    journal.rename(journal.with_name("restore-recovered-" + uuid.uuid4().hex + ".json"))


def restore(key):
    source = archive_path(key)
    try:
        manifest = verify(source, allow_internal=True)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile):
        raise HTTPException(422, "备份校验失败，原数据未改动")
    with sync_service.LOCK:
        safety = create(internal=True)
        required = sum(e['size'] for e in manifest['files']) + 16 * 1024 * 1024
        if shutil.disk_usage(DATA_DIR.parent).free < required:
            raise HTTPException(507, '恢复磁盘空间不足，当前数据及恢复前保护备份保留')
        suffix = uuid.uuid4().hex
        # Siblings guarantee same-filesystem rename. Every original file is retained.
        staged = DATA_DIR.resolve().with_name(DATA_DIR.name + ".staged-" + suffix)
        retained = DATA_DIR.resolve().with_name(DATA_DIR.name + ".retained-" + suffix)
        private_directory(staged)
        with zipfile.ZipFile(source) as archive:
            for entry in manifest["files"]:
                if not entry["path"].startswith("data/"):
                    continue
                relative = entry["path"][5:]
                target = safe_child(staged, relative)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry["path"]))
                if target.suffix == ".sqlite3":
                    with closing(sqlite3.connect(target)) as db:
                        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                            raise HTTPException(422, "备份数据库无效，原数据未改动")
            settings = json.loads(archive.read("settings.json"))
        # Keep at-most-once claims newer than the backup to prevent paid replay.
        current_ops = DATA_DIR / "operations.sqlite3"
        if current_ops.exists():
            target_ops = staged / "operations.sqlite3"
            if not target_ops.exists():
                target_ops.write_bytes(_sqlite_bytes(current_ops))
            else:
                with closing(sqlite3.connect(current_ops)) as old, closing(sqlite3.connect(target_ops)) as new:
                    with new:
                        for row in old.execute("SELECT id,fingerprint,state,created FROM operations"):
                            new.execute("INSERT OR REPLACE INTO operations VALUES (?,?,?,?)", row)
                        # Restore must not roll back today's spent budget or cooldowns.
                        from services.behavior_service import _tables
                        _tables(new)
                        for table, columns in (("behavior_actions", 6), ("behavior_calls", 4)):
                            if old.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                                for row in old.execute("SELECT * FROM " + table):
                                    new.execute("INSERT OR IGNORE INTO " + table + " VALUES (" + ",".join("?" * columns) + ")", row)
                        from services.tts_service import tables
                        tables(new)
                        if old.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='tts_calls'").fetchone():
                            for row in old.execute("SELECT * FROM tts_calls"):
                                new.execute("INSERT OR IGNORE INTO tts_calls VALUES (?,?,?,?,?)", row)
        from services import settings_service
        original_settings = settings_service.load_settings()
        private_directory(RUNTIME_DIR / "restore-state")
        journal = RUNTIME_DIR / "restore-state/restore-pending.json"
        sync_service.write_json(journal, {"retained": str(retained), "staged": str(staged), "settings": original_settings})
        if DATA_DIR.exists():
            DATA_DIR.rename(retained)
        try:
            staged.rename(DATA_DIR)
            allowed = {**settings_service.get_default_settings(), **sync_service.public(settings)}
            allowed.update({k: v for k, v in original_settings.items() if sync_service.SECRET.search(k)})
            for field in ("host", "port"):
                allowed[field] = original_settings.get(field, allowed[field])
            sync_service.write_json(CONFIG_DIR / "settings.json", allowed)
            with sync_service.database() as db:
                db.execute("UPDATE meta SET value=? WHERE key='epoch'", (uuid.uuid4().hex,))
            sync_service.reconcile()
            from services import hybrid_memory_service
            hybrid_memory_service.ensure_index(rebuild=True)
        except BaseException:
            if DATA_DIR.exists():
                DATA_DIR.rename(staged.with_name(staged.name + "-failed"))
            if retained.exists():
                retained.rename(DATA_DIR)
            sync_service.write_json(CONFIG_DIR / "settings.json", original_settings)
            raise
        journal.rename(journal.with_name("restore-completed-" + suffix + ".json"))
    get_logger("migration").info("", extra={"event": "backup_restored", "count": len(manifest["files"])})
    return {"success": True, "safety_backup_id": safety["id"], "original_retained": True,
            "message": "恢复完成，请让所有设备重新同步；账号、会话和供应商密钥保持现状"}
