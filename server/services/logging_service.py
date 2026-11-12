"""Structured logs: allowlisted metadata, module files, bounded rotation.

Free-form messages, exception text, locals, request payloads and URLs are never
serialized. Existing third-party loggers therefore cannot accidentally dump a
provider response or credential. The oldest rotated file goes to the recycle
bin, never permanent deletion.
"""
import ctypes
import hashlib
import json
import logging
import os
import re
import sys
import time
import math
import traceback
import uuid
from contextvars import ContextVar
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path
from urllib.parse import quote


MODULES = ("auth", "chat", "memory", "behavior", "tts", "sync", "resources",
           "migration", "share", "settings", "system")
request_id_context = ContextVar("request_id", default="-")
module_context = ContextVar("log_module", default="system")
_EVENT = re.compile(r"^[a-z][a-z0-9_.]{0,79}$")
_INTEGER_FIELDS = {"status", "count", "bytes", "returned", "total", "offset", "limit",
                   "prompt_tokens", "completion_tokens", "total_tokens", "cached_tokens", "prompt_cache_miss_tokens"}
_HASH_FIELDS = {"role_ref", "chat_ref", "resource_ref"}
_ENUM_FIELDS = {"method", "error_type", "cache_state", "startup_step"}

_STARTUP_STEPS = {
    "data_directory", "backup_recovery", "sync_recovery", "credential_migration",
    "role_api_migration", "sync_migration", "memory_migration", "scheduler_start",
}


def report_startup_failure(error, step):
    """Keep actionable startup diagnostics without dumping paths or credentials."""
    if step not in _STARTUP_STEPS:
        step = "unknown"
    get_logger("system").error(
        "", extra={"event": "server_start_failed", "startup_step": step},
        exc_info=(type(error), error, error.__traceback__),
    )
    if isinstance(error, PermissionError):
        advice = "目录权限不足。请检查运行账号对数据、配置和备份目录的访问及权限设置权；未跳过备份或迁移。"
    else:
        advice = "初始化失败。请根据 runtime/logs/system.jsonl 中的阶段、错误类型和代码位置排查；未继续启动服务。"
    sys.stderr.write(f"[错误] 后端启动失败（阶段：{step}，类型：{type(error).__name__}）：{advice}\n")


def reference(value):
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()[:16]


def get_logger(module):
    if module not in MODULES:
        raise ValueError("Unknown log module")
    return logging.getLogger("zerochat." + module)


def recycle_file(path):
    """Recycle exactly one existing file at an explicit absolute path."""
    path = Path(path).resolve(strict=True)
    if not path.is_file():
        raise ValueError("Only individual files can be recycled")
    if os.name == "nt":
        from ctypes import wintypes

        class SHFILEOPSTRUCTW(ctypes.Structure):
            _fields_ = [("hwnd", wintypes.HWND), ("wFunc", wintypes.UINT),
                        ("pFrom", wintypes.LPCWSTR), ("pTo", wintypes.LPCWSTR),
                        ("fFlags", ctypes.c_ushort), ("fAnyOperationsAborted", wintypes.BOOL),
                        ("hNameMappings", ctypes.c_void_p), ("lpszProgressTitle", wintypes.LPCWSTR)]

        operation = SHFILEOPSTRUCTW()
        source = ctypes.create_unicode_buffer(str(path) + "\0\0")
        operation.wFunc = 3  # FO_DELETE with FOF_ALLOWUNDO moves to recycle bin.
        operation.pFrom = ctypes.cast(source, wintypes.LPCWSTR)
        operation.fFlags = 0x0040 | 0x0010 | 0x0004 | 0x0400
        result = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(operation))
        if result or operation.fAnyOperationsAborted:
            raise OSError("Could not recycle log; rotation stopped")
    else:
        trash = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "Trash"
        (trash / "files").mkdir(parents=True, exist_ok=True, mode=0o700)
        (trash / "info").mkdir(parents=True, exist_ok=True, mode=0o700)
        name = path.name + "-" + uuid.uuid4().hex
        info = trash / "info" / (name + ".trashinfo")
        info.write_text("[Trash Info]\nPath=" + quote(str(path)) + "\nDeletionDate=" +
                        datetime.now().strftime("%Y-%m-%dT%H:%M:%S") + "\n", encoding="utf-8")
        # Same-filesystem rename only; failure leaves the original intact.
        path.rename(trash / "files" / name)


class RecycleRotatingHandler(RotatingFileHandler):
    def doRollover(self):
        if self.stream:
            self.stream.close()
            self.stream = None
        oldest = Path(f"{self.baseFilename}.{self.backupCount}")
        if oldest.exists():
            recycle_file(oldest)
        for index in range(self.backupCount - 1, 0, -1):
            source = Path(f"{self.baseFilename}.{index}")
            if source.exists():
                source.rename(f"{self.baseFilename}.{index + 1}")
        if Path(self.baseFilename).exists():
            Path(self.baseFilename).rename(f"{self.baseFilename}.1")
        if not self.delay:
            self.stream = self._open()

    def handleError(self, record):
        # logging's default handler prints record.args and can disclose secrets.
        sys.stderr.write('{"module":"system","event":"log_write_failed"}\n')


def record_module(record):
    if record.name.startswith("zerochat.") and record.name.split(".")[1] in MODULES:
        return record.name.split(".")[1]
    return module_context.get()


class ModuleFilter(logging.Filter):
    def __init__(self, module):
        super().__init__()
        self.module = module

    def filter(self, record):
        return record_module(record) == self.module


class SafeJsonFormatter(logging.Formatter):
    def format(self, record):
        # Only our explicitly structured events can supply an event identifier.
        event = getattr(record, "event", "legacy_record")
        if not isinstance(event, str) or not _EVENT.fullmatch(event):
            event = "invalid_event"
        payload = {
            "time": datetime.fromtimestamp(record.created, timezone.utc).isoformat(),
            "level": record.levelname, "module": record_module(record),
            "event": event, "request_id": request_id_context.get(),
        }
        for field in _INTEGER_FIELDS:
            value = getattr(record, field, None)
            if type(value) is int:
                payload[field] = value
        duration = getattr(record, "duration_ms", None)
        if isinstance(duration, (int, float)) and math.isfinite(duration):
            payload["duration_ms"] = round(duration, 3)
        for field in _HASH_FIELDS:
            value = getattr(record, field, None)
            if isinstance(value, str) and re.fullmatch(r"[a-f0-9]{16}", value):
                payload[field] = value
        for field in _ENUM_FIELDS:
            value = getattr(record, field, None)
            if isinstance(value, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", value):
                payload[field] = value
        route = getattr(record, "route", None)
        if route in KNOWN_ROUTES:
            payload["route"] = route
        if record.exc_info and record.exc_info[0]:
            payload["error_type"] = record.exc_info[0].__name__
            # No exception messages or source lines, both can contain private text.
            payload["frames"] = [
                {"file": Path(frame.filename).name, "line": frame.lineno, "function": frame.name}
                for frame in traceback.extract_tb(record.exc_info[2])[-12:]
            ]
        return json.dumps(payload, ensure_ascii=True, allow_nan=False)


KNOWN_ROUTES = set()


def configure_logging(directory, max_bytes=2 * 1024 * 1024, backup_count=3):
    if max_bytes < 256 or backup_count < 1:
        raise ValueError("Invalid log retention limits")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    root = logging.getLogger()
    for handler in list(root.handlers):
        root.removeHandler(handler)
        handler.close()
    root.setLevel(logging.INFO)
    formatter = SafeJsonFormatter()
    console = logging.StreamHandler()
    console.setFormatter(formatter)
    root.addHandler(console)
    for module in MODULES:
        handler = RecycleRotatingHandler(
            directory / f"{module}.jsonl", maxBytes=max_bytes,
            backupCount=backup_count, encoding="utf-8", delay=True,
        )
        handler.addFilter(ModuleFilter(module))
        handler.setFormatter(formatter)
        root.addHandler(handler)
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "httpx", "httpcore", "apscheduler"):
        target = logging.getLogger(name)
        for handler in list(target.handlers):
            target.removeHandler(handler)
            handler.close()
        target.propagate = True
        target.disabled = name == "uvicorn.access"
    logging.raiseExceptions = False


def path_module(path):
    parts = path.strip("/").split("/")
    if "share" in parts:
        return "share"
    if "chat-api" in parts:
        return "settings"
    if "backups" in parts:
        return "migration"
    if "tts" in parts:
        return "tts"
    if any(p in parts for p in ("assets", "emojis", "avatar", "avatars", "images", "backgrounds", "audio")):
        return "resources"
    if "memory" in parts:
        return "memory"
    if any(p in parts for p in ("messages", "sync", "roles")):
        return "sync"
    if any(p in parts for p in ("ai", "tasks", "moments", "scheduler", "behavior")):
        return "behavior"
    if any(p in parts for p in ("chat", "chats")):
        return "chat"
    for module in ("auth", "tts", "migration", "share", "settings"):
        if module in parts:
            return module
    return "system"


class RequestLoggingMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        request_id = uuid.uuid4().hex
        # Never trust/echo arbitrary client header values or external URLs.
        id_token = request_id_context.set(request_id)
        module_token = module_context.set(path_module(scope.get("path", "")))
        scope.setdefault("state", {})["request_id"] = request_id
        started = time.perf_counter()
        status, sent, byte_count = 500, False, 0

        async def traced_send(message):
            nonlocal status, sent, byte_count
            if message["type"] == "http.response.start":
                status, sent = message["status"], True
                headers = [(key, value) for key, value in message.get("headers", [])
                           if key.lower() != b"x-request-id"]
                message = {**message, "headers": [*headers, (b"x-request-id", request_id.encode("ascii"))]}
            elif message["type"] == "http.response.body":
                byte_count += len(message.get("body", b""))
            await send(message)

        try:
            await self.app(scope, receive, traced_send)
        except Exception:
            get_logger(module_context.get()).exception("", extra={"event": "request_failed"})
            if not sent:
                from starlette.responses import JSONResponse
                response = JSONResponse(
                    {"detail": "服务处理失败，请保留请求编号并手动重试", "request_id": request_id},
                    status_code=500,
                    headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
                )
                await response(scope, receive, traced_send)
            else:
                raise
        finally:
            route = getattr(scope.get("route"), "path", "unknown")
            extra = {"event": "request_completed", "route": route,
                     "method": scope["method"], "status": status, "bytes": byte_count,
                     "duration_ms": (time.perf_counter() - started) * 1000}
            if module_context.get() == "resources":
                extra["resource_ref"] = reference(scope.get("path", ""))
                extra["cache_state"] = "not_modified" if status == 304 else "body" if status == 200 else "failed"
            if status >= 400:
                extra["error_type"] = "HTTP" + str(status)
            log = get_logger(module_context.get())
            log.log(logging.ERROR if status >= 500 else logging.WARNING if status >= 400 else logging.INFO,
                    "", extra=extra)
            module_context.reset(module_token)
            request_id_context.reset(id_token)
