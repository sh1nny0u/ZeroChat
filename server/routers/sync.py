"""Authenticated synchronization, migration reports and backup management."""
import asyncio
from contextlib import asynccontextmanager
from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from services import sync_service, backup_service

router = APIRouter()
# Active operations may overlap; snapshots alone wait for a quiescent boundary.
class WriteGate:
    def __init__(self):
        self.loop = None
        self.condition = asyncio.Condition()
        self.tasks = {}
        self.exclusive_task = None
        self.snapshot_lock = asyncio.Lock()
        self.paused = False

    def bind(self):
        loop = asyncio.get_running_loop()
        if self.loop is not loop:
            if self.tasks or self.paused:
                raise RuntimeError('Write gate cannot span concurrent event loops')
            self.loop = loop
            self.condition = asyncio.Condition()
            self.snapshot_lock = asyncio.Lock()

    async def __aenter__(self):
        self.bind()
        task = asyncio.current_task()
        async with self.condition:
            if task not in self.tasks and task is not self.exclusive_task:
                await self.condition.wait_for(lambda: not self.paused)
            self.tasks[task] = self.tasks.get(task, 0) + 1

    async def __aexit__(self, *args):
        task = asyncio.current_task()
        async with self.condition:
            self.tasks[task] -= 1
            if not self.tasks[task]:
                del self.tasks[task]
            self.condition.notify_all()

    @asynccontextmanager
    async def exclusive(self):
        self.bind()
        task = asyncio.current_task()
        async with self.snapshot_lock:
            async with self.condition:
                self.paused = True
                try:
                    await self.condition.wait_for(lambda: not self.tasks)
                except BaseException:
                    self.paused = False
                    self.condition.notify_all()
                    raise
                self.exclusive_task = task
            try:
                yield
            finally:
                async with self.condition:
                    self.exclusive_task = None
                    self.paused = False
                    self.condition.notify_all()


WRITE_GATE = WriteGate()


class Operation(BaseModel):
    operation_id: str = Field(min_length=8, max_length=128)
    kind: str = Field(max_length=30)
    id: str = Field(max_length=128)
    base_version: str | None = Field(default=None, max_length=64)
    payload: dict = Field(default_factory=dict)
    deleted: bool = False


class Restore(BaseModel):
    backup_id: str = Field(max_length=128)
    confirm: str


@router.get("/sync/changes")
async def changes(after: int = 0, epoch: str | None = None, limit: int = 100):
    return await run_in_threadpool(sync_service.feed, after, epoch, limit)


@router.post("/sync/entities")
async def push(body: Operation):
    try:
        return await run_in_threadpool(sync_service.mutate, body.model_dump())
    except (ValueError, TypeError):
        raise HTTPException(422, "同步字段无效，原数据保留")


@router.get("/sync/versions/{kind}/{key}")
async def versions(kind: str, key: str):
    sync_service.identity(key)
    with sync_service.database() as db:
        rows = db.execute("SELECT * FROM versions WHERE kind=? AND id=? ORDER BY rowid DESC LIMIT 50", (kind, key)).fetchall()
    return {"versions": [sync_service.unpack(r) for r in rows]}


@router.get("/migration/report")
async def report():
    return sync_service.migration_report()


@router.post("/migration/run")
async def migrate():
    return await run_in_threadpool(sync_service.migrate)


@router.get("/backups")
async def backups():
    return {"backups": await run_in_threadpool(backup_service.list_backups), "max_upload_bytes": backup_service.MAX_BYTES}


@router.post("/backups")
async def create():
    return await run_in_threadpool(backup_service.create)


@router.get("/backups/{key}/download")
async def download(key: str):
    path = backup_service.archive_path(key)
    try:
        manifest = await run_in_threadpool(backup_service.verify, path)
    except (ValueError, KeyError, OSError):
        raise HTTPException(404, "备份不存在或不可下载")
    if manifest.get("contains_credentials"):
        raise HTTPException(403, "内部保护快照不可下载")
    return FileResponse(path, media_type="application/zip", filename="zerochat-" + key + ".zip")


@router.post("/backups/import")
async def upload(file: UploadFile = File(...)):
    content = await file.read(backup_service.MAX_BYTES + 1)
    return await run_in_threadpool(backup_service.import_backup, content)


@router.post("/backups/restore")
async def restore(body: Restore):
    if body.confirm != "恢复并覆盖业务数据":
        raise HTTPException(422, "请先确认恢复范围")
    result = await run_in_threadpool(backup_service.restore, body.backup_id)
    from services import scheduler_service
    scheduler = scheduler_service.get_scheduler()
    if scheduler.running:
        for job in scheduler.get_jobs():
            if job.id.startswith(("proactive_", "task_")):
                scheduler.remove_job(job.id)
        scheduler_service._init_proactive_jobs()
        scheduler_service._init_scheduled_tasks()
    return result


class DataWriteMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"].startswith("/api/") and not scope["path"].startswith("/api/auth/") and scope["path"] != "/api/health":
            snapshot = scope.get('method') == 'POST' and scope['path'] in ('/api/backups', '/api/backups/restore', '/api/backups/import', '/api/migration/run')
            async def protected():
                async with WRITE_GATE.exclusive() if snapshot else WRITE_GATE:
                    await self.app(scope, receive, send)
            # Keep the same task as the gate owner for nested business operations.
            # Cancellation cannot release the barrier before a threadpool commit.
            operation = asyncio.create_task(protected())
            try:
                await asyncio.shield(operation)
            except asyncio.CancelledError:
                while not operation.done():
                    try:
                        await asyncio.shield(operation)
                    except asyncio.CancelledError:
                        continue
                    except BaseException:
                        break
                if not operation.cancelled():
                    operation.exception()
                raise
        else:
            await self.app(scope, receive, send)
