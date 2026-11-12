"""
任务调度路由
"""
import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional, List
from pydantic import BaseModel, Field, field_validator
from typing import Literal
from fastapi import APIRouter, HTTPException

router = APIRouter()
from services.sync_service import local_mutation

from services.paths_service import DATA_DIR
TASKS_FILE = DATA_DIR / "tasks" / "scheduled.json"

class TaskCreate(BaseModel):
    id: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9_-]{1,100}$")
    chat_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    role_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    message: str = Field(max_length=100000)
    ai_prompt: Optional[str] = Field(default="", max_length=100000)
    trigger_time: str  # ISO format
    repeat: Optional[Literal["daily", "weekly", "none"]] = None

    @field_validator("trigger_time")
    @classmethod
    def valid_time(cls, value):
        if len(value) > 40:
            raise ValueError("Invalid time")
        datetime.fromisoformat(value)
        return value

def load_tasks() -> List[dict]:
    if TASKS_FILE.exists():
        with open(TASKS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return []

def save_tasks(tasks: List[dict]):
    TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    from services.sync_service import write_json
    write_json(TASKS_FILE, tasks)

@router.get("/tasks")
async def list_tasks():
    """获取所有任务"""
    tasks = load_tasks()
    return {"tasks": tasks}

@router.get("/tasks/{role_id}")
async def get_role_tasks(role_id: str):
    """获取角色任务"""
    tasks = load_tasks()
    role_tasks = [t for t in tasks if t.get("role_id") == role_id]
    return {"tasks": role_tasks}


@router.post("/tasks/{task_id}/retry")
@local_mutation
async def retry_task(task_id: str):
    """Only definite failures can be retried, explicitly by the administrator."""
    values = load_tasks()
    task = next((t for t in values if t["id"] == task_id), None)
    if not task:
        raise HTTPException(404, "任务不存在")
    if task.get("last_status") != "failed" or task.get("enabled", True):
        raise HTTPException(409, "此任务不能重试；结果未确认时不会自动重复调用")
    task.update(enabled=True, last_status="pending", trigger_time=datetime.now().isoformat())
    save_tasks(values)
    from services.scheduler_service import schedule_task
    schedule_task(task)
    return task

@router.post("/tasks")
@local_mutation
async def create_task(task: TaskCreate):
    """创建任务"""
    tasks = load_tasks()
    
    if task.id:
        existing = next((t for t in tasks if t["id"] == task.id), None)
        if existing:
            if any(existing.get(k) != getattr(task, k) for k in ("chat_id", "role_id", "message", "trigger_time", "ai_prompt", "repeat")):
                raise HTTPException(409, "任务编号冲突，原任务未修改")
            return existing
    from routers.ai_behavior import load_role
    if not load_role(task.role_id):
        raise HTTPException(404, "角色不存在")
    datetime.fromisoformat(task.trigger_time)
    new_task = {
        "id": task.id or str(uuid.uuid4()),
        "chat_id": task.chat_id,
        "role_id": task.role_id,
        "message": task.message,
        "ai_prompt": task.ai_prompt,
        "trigger_time": task.trigger_time,
        "repeat": task.repeat,
        "enabled": True,
        "created_at": datetime.now().isoformat()
    }
    
    tasks.append(new_task)
    save_tasks(tasks)
    from services.scheduler_service import schedule_task
    schedule_task(new_task)
    return new_task

@router.put("/tasks/{task_id}/toggle")
@local_mutation
async def toggle_task(task_id: str):
    """启用/禁用任务"""
    tasks = load_tasks()
    for t in tasks:
        if t["id"] == task_id:
            t["enabled"] = not t.get("enabled", True)
            save_tasks(tasks)
            from services.scheduler_service import schedule_task
            schedule_task(t)
            return t
    return {"error": "not found"}

@router.delete("/tasks/{task_id}")
@local_mutation
async def delete_task(task_id: str):
    """删除任务"""
    tasks = load_tasks()
    tasks = [t for t in tasks if t["id"] != task_id]
    save_tasks(tasks)
    from services.scheduler_service import get_scheduler
    scheduler = get_scheduler()
    if scheduler.get_job("task_" + task_id):
        scheduler.remove_job("task_" + task_id)
    return {"success": True}

@router.get("/tasks/status/summary")
async def scheduler_status():
    """获取调度器状态"""
    tasks = load_tasks()
    enabled_count = len([t for t in tasks if t.get("enabled", True)])
    return {
        "total_tasks": len(tasks),
        "enabled_tasks": enabled_count,
        "status": "running"
    }
