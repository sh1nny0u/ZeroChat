"""Single administrator and revocable opaque sessions, stored locally."""
import hashlib
import hmac
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager

from fastapi import HTTPException
from services.paths_service import CONFIG_DIR
from services.logging_service import get_logger
from tools.data_protection import private_directory

logger = get_logger("auth")
# Keep the existing NOT NULL column: zero means valid until explicitly revoked.
# Valid legacy sessions adopt this policy on use; expired/revoked tokens stay invalid.
PERSISTENT_SESSION = 0
LEGACY_IDLE_SECONDS = 7 * 86400


@contextmanager
def database():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(CONFIG_DIR / "auth.sqlite3", timeout=30)
    try:
        with db:
            db.row_factory = sqlite3.Row
            db.executescript("""
              CREATE TABLE IF NOT EXISTS administrator (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), username TEXT NOT NULL,
                salt TEXT NOT NULL, password_hash TEXT NOT NULL, identity TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, device TEXT NOT NULL,
                created REAL NOT NULL, last_seen REAL NOT NULL, expires REAL NOT NULL,
                revoked INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS attempts (bucket TEXT PRIMARY KEY,
                count INTEGER NOT NULL, reset_at REAL NOT NULL);
            """)
            db.execute("BEGIN IMMEDIATE")
            yield db
    finally:
        db.close()


def initialize():
    private_directory(CONFIG_DIR)
    # Never regenerate a bootstrap token on restart. It is read on the server,
    # not returned by a public API or printed in request/startup logs.
    path = CONFIG_DIR / "setup-token.txt"
    if not path.exists():
        try:
            with path.open("x", encoding="ascii") as stream:
                stream.write("".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(12)))
        except FileExistsError:
            pass
    if os.name != "nt":
        path.chmod(0o600)
    with database():
        pass


def initialized():
    with database() as db:
        return db.execute("SELECT 1 FROM administrator").fetchone() is not None


def password_hash(password, salt):
    return hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt),
                          n=32768, r=8, p=3, maxmem=64 * 1024 * 1024).hex()


def validate_password(password):
    if not 6 <= len(password) <= 14:
        raise HTTPException(422, "密码须为 6 至 14 个字符")


def _check_limit(db, bucket):
    now = time.time()
    row = db.execute("SELECT * FROM attempts WHERE bucket=?", (bucket,)).fetchone()
    if row and row["reset_at"] > now and row["count"] >= 10:
        raise HTTPException(429, "尝试次数过多，请 15 分钟后手动重试", headers={"Retry-After": "900"})
    db.execute("""INSERT INTO attempts VALUES (?,1,?) ON CONFLICT(bucket) DO UPDATE SET
      count=CASE WHEN reset_at<=? THEN 1 ELSE count+1 END,
      reset_at=CASE WHEN reset_at<=? THEN excluded.reset_at ELSE reset_at END""",
               (bucket, now + 900, now, now))
    # Failed authentication must consume the attempt even if its transaction aborts.
    db.commit()
    db.execute("BEGIN IMMEDIATE")


def _session(db, device):
    now = time.time()
    token = secrets.token_urlsafe(32)
    sid = uuid.uuid4().hex
    db.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,0)",
               (sid, hashlib.sha256(token.encode()).hexdigest(), device[:100],
                now, now, PERSISTENT_SESSION))
    admin = db.execute("SELECT username,identity FROM administrator").fetchone()
    return {"token": token, "session_id": sid, "username": admin["username"],
            "identity": admin["identity"], "expires_at": None, "persistent": True}


def setup(username, password, device, setup_token, peer):
    validate_password(password)
    with database() as db:
        if db.execute("SELECT 1 FROM administrator").fetchone():
            raise HTTPException(409, "管理员已创建，初始化入口已关闭")
        _check_limit(db, "setup:" + peer)
        expected = (CONFIG_DIR / "setup-token.txt").read_text(encoding="ascii").strip()
        if not hmac.compare_digest(expected, setup_token):
            raise HTTPException(403, "初始化凭证不正确，请在服务器本机查看")
        if db.execute("SELECT 1 FROM administrator").fetchone():
            raise HTTPException(409, "管理员已创建，初始化入口已关闭")
        if not 6 <= len(username.strip()) <= 14:
            raise HTTPException(422, "账号须为 6 至 14 个字符")
        salt = secrets.token_hex(16)
        db.execute("INSERT INTO administrator VALUES (1,?,?,?,?)",
                   (username.strip(), salt, password_hash(password, salt), uuid.uuid4().hex))
        result = _session(db, device)
    logger.info("", extra={"event": "administrator_created"})
    return result


def login(username, password, device, peer):
    with database() as db:
        _check_limit(db, "login:" + peer)
        _check_limit(db, "administrator")
        admin = db.execute("SELECT * FROM administrator").fetchone()
        salt = admin["salt"] if admin else "00" * 16
        candidate = password_hash(password, salt)
        if not admin or not hmac.compare_digest(candidate, admin["password_hash"]) or username != admin["username"]:
            logger.warning("", extra={"event": "login_rejected"})
            raise HTTPException(401, "账号或密码不正确")
        db.execute("DELETE FROM attempts WHERE bucket IN (?,?)", ("login:" + peer, "administrator"))
        return _session(db, device)


def authenticate(token):
    if not token or len(token) > 256:
        raise HTTPException(401, "请登录管理员账号")
    with database() as db:
        row = db.execute("SELECT * FROM sessions WHERE token_hash=?",
                         (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        now = time.time()
        if not row or row["revoked"] or (row["expires"] != PERSISTENT_SESSION and
                (row["expires"] <= now or row["last_seen"] + LEGACY_IDLE_SECONDS <= now)):
            raise HTTPException(401, "登录已失效，请重新登录")
        db.execute("UPDATE sessions SET last_seen=?,expires=? WHERE id=?", (now, PERSISTENT_SESSION, row["id"]))
        admin = db.execute("SELECT username,identity FROM administrator").fetchone()
        return {"session_id": row["id"], "username": admin["username"], "identity": admin["identity"]}


def sessions(current):
    with database() as db:
        rows = db.execute("""SELECT id,device,created,last_seen,expires FROM sessions
          WHERE revoked=0 AND (expires=? OR (expires>? AND last_seen>?)) ORDER BY created DESC""",
                          (PERSISTENT_SESSION, time.time(), time.time() - LEGACY_IDLE_SECONDS)).fetchall()
        return [{**dict(row), "expires": None, "persistent": True,
                 "current": row["id"] == current} for row in rows]


def revoke(sid):
    with database() as db:
        db.execute("UPDATE sessions SET revoked=1 WHERE id=?", (sid,))
    logger.info("", extra={"event": "session_revoked"})


def change_password(old_password, new_password, current):
    validate_password(new_password)
    with database() as db:
        _check_limit(db, "change:" + current)
        admin = db.execute("SELECT * FROM administrator").fetchone()
        if not hmac.compare_digest(password_hash(old_password, admin["salt"]), admin["password_hash"]):
            raise HTTPException(403, "旧密码不正确")
        salt = secrets.token_hex(16)
        db.execute("UPDATE administrator SET salt=?, password_hash=?", (salt, password_hash(new_password, salt)))
        db.execute("UPDATE sessions SET revoked=1 WHERE id<>?", (current,))
    logger.info("", extra={"event": "password_changed"})


def reset_password(new_password):
    validate_password(new_password)
    with database() as db:
        if not db.execute("SELECT 1 FROM administrator").fetchone():
            raise ValueError("Administrator has not been created")
        salt = secrets.token_hex(16)
        db.execute("UPDATE administrator SET salt=?, password_hash=?", (salt, password_hash(new_password, salt)))
        db.execute("UPDATE sessions SET revoked=1")
        db.execute("DELETE FROM attempts")
    logger.info("", extra={"event": "password_reset_locally"})
