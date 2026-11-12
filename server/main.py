"""
ZeroChat Server - 后端服务入口
双击运行即可启动 HTTP 服务
"""
import sys
import os
import json
import uuid
from pathlib import Path
from datetime import datetime
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from services.logging_service import (
    KNOWN_ROUTES, RequestLoggingMiddleware, configure_logging, get_logger,
    request_id_context, report_startup_failure,
)
from services.paths_service import ROOT_DIR, CONFIG_DIR, DATA_DIR, RUNTIME_DIR

# 创建必要目录
for d in [CONFIG_DIR, DATA_DIR, RUNTIME_DIR, 
          DATA_DIR / "roles"]:
    d.mkdir(parents=True, exist_ok=True)

configure_logging(RUNTIME_DIR / "logs")
logger = get_logger("system")

# 加载配置
def load_config():
    config_file = CONFIG_DIR / "settings.json"
    default_config = {
        "host": "0.0.0.0",
        "port": 8000,
        "ai_api_url": "",
        "ai_api_key": "",
        "ai_model": "gpt-3.5-turbo"
    }
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return {**default_config, **json.load(f)}
    else:
        with open(config_file, "w", encoding="utf-8") as f:
            json.dump(default_config, f, indent=2, ensure_ascii=False)
        return default_config

CONFIG = load_config()

# 导入路由
from routers import chat, roles, moments, tasks, settings
from routers import ai_behavior, auth, groups, sync, role_share, memory, behavior, tts
from services import auth_service
from services.access_service import AccessMiddleware
auth_service.initialize()
from services import scheduler_service, delivery_service

# AI 事件回调
async def handle_ai_event(event_data: dict):
    """处理调度器触发的 AI 事件"""
    from routers.ai_behavior import AIEvent, handle_ai_event as process_event
    token = request_id_context.set(uuid.uuid4().hex)
    try:
        event = AIEvent(**event_data)
        from services.event_service import execute
        async with sync.WRITE_GATE:
            return await execute(event)
    except Exception:
        get_logger("behavior").exception("", extra={"event": "scheduled_event_failed"})
        raise
    finally:
        request_id_context.reset(token)

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("", extra={"event": "server_starting"})
    
    from services import backup_service, sync_service, role_api_service
    from starlette.concurrency import run_in_threadpool
    from services import settings_service
    from services import hybrid_memory_service
    step = "data_directory"
    try:
        # 角色目录（不创建默认角色，留空即可）
        (DATA_DIR / "roles").mkdir(parents=True, exist_ok=True)
        for step, operation in (
            ("backup_recovery", backup_service.recover_interrupted),
            ("sync_recovery", sync_service.recover_pending),
            ("credential_migration", settings_service.migrate_credentials),
            ("role_api_migration", role_api_service.migrate_legacy),
            ("sync_migration", sync_service.migrate),
            ("memory_migration", hybrid_memory_service.migrate),
        ):
            await run_in_threadpool(operation)

        step = "scheduler_start"
        scheduler_service.set_event_callback(handle_ai_event)
        scheduler_service.start_scheduler()
    except Exception as error:
        report_startup_failure(error, step)
        raise
    logger.info("", extra={"event": "server_ready"})
    try:
        yield
    finally:
        scheduler_service.stop_scheduler()
        logger.info("", extra={"event": "server_stopped"})

# 创建应用
app = FastAPI(
    title="ZeroChat Server",
    description="ZeroChat 后端服务",
    version="2.0.0",
    docs_url=None, redoc_url=None, openapi_url=None,
    lifespan=lifespan
)

@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, error: RequestValidationError):
    # Pydantic's default response includes rejected input, possibly a password.
    return JSONResponse({"detail": "请求字段无效，请检查输入后重试", "request_id": request.state.request_id},
                        status_code=422, headers={"Cache-Control": "no-store"})

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=[v.strip() for v in os.environ.get("ZEROCHAT_CORS_ORIGINS", "").split(",") if v.strip()],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Request-ID"],
)

app.add_middleware(sync.DataWriteMiddleware)
app.add_middleware(AccessMiddleware)
app.add_middleware(RequestLoggingMiddleware)

# 注册路由
app.include_router(delivery_service.router, prefix="/api", tags=["Resources"])
app.include_router(sync.router, prefix="/api", tags=["Sync and Backups"])
app.include_router(groups.router, prefix="/api", tags=["Groups"])
app.include_router(auth.router, prefix="/api", tags=["Auth"])
app.include_router(chat.router, prefix="/api", tags=["Chat"])
app.include_router(roles.router, prefix="/api", tags=["Roles"])
app.include_router(role_share.router, prefix="/api", tags=["Role Sharing"])
app.include_router(memory.router, prefix="/api", tags=["Memory"])
app.include_router(behavior.router, prefix="/api", tags=["Life and Adaptation"])
app.include_router(tts.router, prefix="/api", tags=["Voice"])
app.include_router(moments.router, prefix="/api", tags=["Moments"])
app.include_router(tasks.router, prefix="/api", tags=["Tasks"])
app.include_router(ai_behavior.router, prefix="/api", tags=["AI Behavior"])
app.include_router(settings.router, prefix="/api", tags=["Settings"])
from routers import notifications
app.include_router(notifications.router, prefix="/api", tags=["Notifications"])

@app.get("/")
async def root():
    return {"status": "ok", "message": "ZeroChat Server Running", "version": "2.0.0",
            "license": "AGPL-3.0-only", "source_url": source_url()}


def source_url():
    return os.environ.get("ZEROCHAT_SOURCE_URL", "https://github.com/sh1nny0u/ZeroChat/tree/V2.0.0.261112")


@app.get("/api/license")
async def license_information():
    return {"version": "2.0.0", "license": "AGPL-3.0-only", "source_url": source_url(),
            "license_url": "https://www.gnu.org/licenses/agpl-3.0.html",
            "notice": "No warranty. Original MIT copyright and permission notices are retained."}

@app.get("/api/health")
async def health():
    return {"status": "healthy", "timestamp": datetime.now().isoformat()}

@app.get("/api/scheduler/status")
async def scheduler_status():
    """获取调度器状态"""
    return scheduler_service.get_scheduler_status()


KNOWN_ROUTES.update(route.path for route in app.routes if hasattr(route, "path"))

if __name__ == "__main__":
    print("\n" + "=" * 50)
    print("  ZeroChat Server")
    print("  按 Ctrl+C 停止服务")
    print("=" * 50 + "\n")
    
    uvicorn.run(
        "main:app",
        host=CONFIG["host"],
        port=CONFIG["port"],
        reload=False,
        log_level="info",
        log_config=None,
        access_log=False,
        forwarded_allow_ips=os.environ.get("ZEROCHAT_TRUSTED_PROXIES", "127.0.0.1"),
    )
