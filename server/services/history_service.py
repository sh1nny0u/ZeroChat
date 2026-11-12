"""Indexed history with durable legacy backup and stable keyset cursors."""
import base64
import hashlib
import json
import shutil
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from services.logging_service import get_logger

logger = get_logger("migration")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    delta = parsed.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return (delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds


@contextmanager
def database(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(directory / "messages.sqlite3", timeout=30)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA busy_timeout=30000")
        connection.executescript("""
          CREATE TABLE IF NOT EXISTS messages (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
            sort_time INTEGER NOT NULL, payload TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS history_order ON messages(sort_time, id);
          CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        # Serialize migration and writers across requests and processes.
        connection.execute("BEGIN IMMEDIATE")
        if not connection.execute("SELECT 1 FROM metadata WHERE key='legacy_imported'").fetchone():
            source = directory / "messages.json"
            report = {"version": 1, "imported": 0, "original_retained": True}
            if source.exists():
                backup = directory / ("messages.pre-sqlite-" + uuid.uuid4().hex + ".json")
                shutil.copyfile(source, backup)
                if digest(source) != digest(backup):
                    raise ValueError("Legacy backup verification failed")
                # Full decoding occurs only during this backed-up migration.
                data = json.loads(backup.read_text(encoding="utf-8"))
                if not isinstance(data, dict) or not isinstance(data.get("messages"), list):
                    raise ValueError("Invalid legacy history; original retained")
                for message in data["messages"]:
                    insert(connection, message)
                report.update(imported=len(data["messages"]), backup=backup.name,
                              sha256=digest(backup))
            connection.execute("INSERT INTO metadata VALUES ('legacy_imported', ?)",
                               (json.dumps(report),))
            (directory / "migration-report.json").write_text(
                json.dumps(report, indent=2), encoding="utf-8")
            logger.info("", extra={"event": "history_migrated", "count": report["imported"]})
        connection.commit()
        yield connection
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def insert(connection, message):
    if not isinstance(message, dict) or not isinstance(message.get("id"), str) or not message["id"]:
        raise ValueError("Invalid message identity; original retained")
    # Untimed legacy rows stay recoverable; valid rows use timestamp plus ID.
    order = timestamp(message["timestamp"]) if message.get("timestamp") else 0
    existing = connection.execute("SELECT payload FROM messages WHERE id=?", (message["id"],)).fetchone()
    if existing:
        old = json.loads(existing[0])
        def identity(value):
            return (value.get("content"), value.get("sender_id"),
                    timestamp(value["timestamp"]) if value.get("timestamp") else 0,
                    value.get("type") or "text",
                    value.get("quote_id") or value.get("quoted_message_id"),
                    value.get("quote_content") or value.get("quoted_preview_text"))
        if identity(old) != identity(message):
            raise ValueError("Conflicting message identity; original retained")
    return connection.execute(
        "INSERT OR IGNORE INTO messages(id, sort_time, payload) VALUES (?,?,?)",
        (message["id"], order, json.dumps(message, ensure_ascii=False))).rowcount


def attach_audio(directory, identity, url, duration_ms):
    """Promote an already durable text row and expose the update to incremental readers."""
    with database(directory) as db:
        row = db.execute("SELECT payload FROM messages WHERE id=?", (identity,)).fetchone()
        if not row:
            raise ValueError("Message no longer exists")
        payload = json.loads(row[0])
        if payload.get("type") != "text":
            raise ValueError("Message is not eligible for voice")
        payload.update(type="voice", audio_url=url, duration_ms=duration_ms)
        current = db.execute("SELECT COALESCE(MAX(seq),0) FROM messages").fetchone()[0]
        allocated = db.execute("SELECT seq FROM sqlite_sequence WHERE name='messages'").fetchone()
        seq = max(current, allocated[0] if allocated else 0) + 1
        db.execute("UPDATE messages SET seq=?, payload=? WHERE id=?", (seq, json.dumps(payload, ensure_ascii=False), identity))
        db.execute("UPDATE sqlite_sequence SET seq=? WHERE name='messages'", (seq,))
        db.commit()


def decode_cursor(cursor):
    try:
        value = json.loads(base64.urlsafe_b64decode(cursor.encode()))
        if len(value) != 2 or not isinstance(value[0], int) or not isinstance(value[1], str):
            raise ValueError()
        return value
    except Exception as error:
        raise ValueError("Invalid history cursor") from error


def page(directory, limit=50, before=None, after=None, offset=0):
    if not 1 <= limit <= 200 or offset < 0 or (before and after is not None):
        raise ValueError("Invalid page parameters")
    with database(directory) as db:
        db.execute("BEGIN")
        total = db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        high_water = db.execute("SELECT COALESCE(MAX(seq),0) FROM messages").fetchone()[0]
        revision = db.execute("SELECT value FROM metadata WHERE key='revision'").fetchone()
        params = []
        where = ""
        if before:
            order, identity = decode_cursor(before)
            where = " WHERE (sort_time,id) < (?,?)"
            params += [order, identity]
        elif after is not None:
            where = " WHERE seq > ?"
            params.append(after)
        ordering = "seq ASC" if after is not None else "sort_time DESC, id DESC"
        rows = db.execute("SELECT * FROM messages" + where + " ORDER BY " + ordering +
                          " LIMIT ? OFFSET ?", (*params, limit + 1, offset)).fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]
        next_after = rows[-1]["seq"] if rows else after
        if after is None:
            rows.reverse()
        cursor = base64.urlsafe_b64encode(json.dumps(
            [rows[0]["sort_time"], rows[0]["id"]]).encode()).decode() if rows else None
        messages = [{**json.loads(row["payload"]), "server_seq": row["seq"]} for row in rows]
        return {"messages": messages, "total": total, "has_more": has_more,
                "next_cursor": cursor, "high_water": high_water, "next_after": next_after,
                "revision": revision[0] if revision else "initial"}


def append(directory, messages):
    with database(directory) as db, db:
        added = sum(insert(db, message) for message in messages)
        total = db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        return {"success": True, "added": added, "total": total}


def remove(directory, identity=None):
    with database(directory) as db, db:
        if identity is None:
            removed = db.execute("DELETE FROM messages").rowcount
        else:
            removed = db.execute("DELETE FROM messages WHERE id=?", (identity,)).rowcount
        db.execute("INSERT OR REPLACE INTO metadata VALUES ('revision',?)", (uuid.uuid4().hex,))
        return {"success": True, "removed": removed,
                "total": db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]}
