"""Durable at-most-once claims; no final model response cache."""
import hashlib
import asyncio
import json
import sqlite3
import time
from contextlib import contextmanager
from fastapi import HTTPException
from services.paths_service import DATA_DIR

# Single-worker runtime ownership. A persisted claim without a live owner after
# restart is recoverable only through explicit user confirmation, never replay.
_active = set()


def in_flight(identity):
    return identity in _active


@contextmanager
def database():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DATA_DIR / "operations.sqlite3", timeout=30)
    try:
        with db:
            db.row_factory = sqlite3.Row
            db.execute("""CREATE TABLE IF NOT EXISTS operations(
              id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, state TEXT NOT NULL,
              created REAL NOT NULL)""")
            db.execute("BEGIN IMMEDIATE")
            yield db
    finally:
        db.close()


def claim(identity, payload):
    if not identity or len(identity) > 256:
        raise HTTPException(422, "缺少有效请求编号，请更新客户端")
    fingerprint = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=True).encode()).hexdigest()
    with database() as db:
        row = db.execute("SELECT * FROM operations WHERE id=?", (identity,)).fetchone()
        if row:
            if row["fingerprint"] != fingerprint:
                raise HTTPException(409, "请求编号已用于其他内容，已阻止重复操作")
            raise HTTPException(409, "此请求已受理；请刷新记录确认结果，不会再次调用供应商")
        db.execute("INSERT INTO operations VALUES (?,?,?,?)", (identity, fingerprint, "claimed", time.time()))
    _active.add(identity)
    try:
        task = asyncio.current_task()
    except RuntimeError:
        task = None
    if task is not None:
        task.add_done_callback(lambda _: _active.discard(identity))


def finish(identity, state="completed"):
    with database() as db:
        db.execute("UPDATE operations SET state=? WHERE id=?", (state, identity))
    _active.discard(identity)


def status(identity):
    with database() as db:
        row = db.execute("SELECT state FROM operations WHERE id=?", (identity,)).fetchone()
        return row["state"] if row else "missing"


def failure_state(error):
    return "uncertain" if any(word in (error or "") for word in ("超时", "未确认")) else "failed"
