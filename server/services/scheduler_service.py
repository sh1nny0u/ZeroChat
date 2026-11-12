"""
调度器服务
管理定时任务、主动消息、朋友圈 AI 行为
"""
import json
import random
import asyncio
from datetime import datetime, timedelta
import os
import socket
import hashlib
import uuid
from pathlib import Path
from typing import Optional, Dict, List, Callable
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.date import DateTrigger
from services.logging_service import get_logger, reference

logger = get_logger("behavior")

from services.paths_service import DATA_DIR
ROLES_DIR = DATA_DIR / "roles"
TASKS_DIR = DATA_DIR / "tasks"

# 全局调度器实例
_scheduler: Optional[AsyncIOScheduler] = None
_event_callback: Optional[Callable] = None
_leader_socket = None
_active_tasks = set()

def get_scheduler() -> AsyncIOScheduler:
    global _scheduler
    if _scheduler is None:
        _scheduler = AsyncIOScheduler()
    return _scheduler

def set_event_callback(callback: Callable):
    """设置事件回调函数（用于触发 AI 行为）"""
    global _event_callback
    _event_callback = callback

def start_scheduler():
    """启动调度器"""
    global _leader_socket
    if _leader_socket is None:
        from services.paths_service import CONFIG_DIR
        port = 20000 + int(hashlib.sha256(str(CONFIG_DIR.resolve()).encode()).hexdigest()[:8], 16) % 20000
        leader = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            leader.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        try:
            leader.bind(("127.0.0.1", port))
            leader.listen(1)
        except OSError:
            leader.close()
            logger.info("", extra={"event": "scheduler_owned_by_other_process"})
            return
        _leader_socket = leader
    scheduler = get_scheduler()
    if not scheduler.running:
        scheduler.configure(job_defaults={"coalesce": True, "max_instances": 1})
        scheduler.start()
        logger.info("", extra={"event": "scheduler_started"})
        
        # 初始化所有调度任务
        _init_proactive_jobs()
        _init_scheduled_tasks()
        _init_moment_jobs()
        scheduler.add_job(_check_moment_interactions, "interval", minutes=5, id="moment_interactions", max_instances=1, coalesce=True)
        scheduler.add_job(_refresh_jobs, "interval", seconds=30, id="refresh_jobs", max_instances=1, coalesce=True)

def stop_scheduler():
    """停止调度器"""
    global _leader_socket
    scheduler = get_scheduler()
    if scheduler.running:
        scheduler.shutdown()
    if _leader_socket is not None:
        _leader_socket.close()
        _leader_socket = None
        logger.info("", extra={"event": "scheduler_stopped"})

# ========== 主动消息调度 ==========

def _init_proactive_jobs():
    """初始化所有角色的主动消息调度"""
    if not ROLES_DIR.exists():
        return
    
    for role_dir in ROLES_DIR.iterdir():
        if role_dir.is_dir():
            schedule_proactive_for_role(role_dir.name)

def schedule_proactive_for_role(role_id: str):
    """为角色调度主动消息"""
    scheduler = get_scheduler()
    job_id = f"proactive_{role_id}"
    
    # 移除旧任务
    if not scheduler.running:
        return
    
    # 加载角色配置
    profile_file = ROLES_DIR / role_id / "profile.json"
    if not profile_file.exists():
        return
    
    with open(profile_file, "r", encoding="utf-8") as f:
        role = json.load(f)
    if role.get("deleted"):
        if scheduler.get_job(job_id):
            scheduler.remove_job(job_id)
        return
    
    proactive_config = role.get("proactive_config", {})
    if not proactive_config.get("enabled", False):
        if scheduler.get_job(job_id):
            scheduler.remove_job(job_id)
        return
    existing = scheduler.get_job(job_id)
    fingerprint = hashlib.sha256(json.dumps(proactive_config, sort_keys=True).encode()).hexdigest()
    if existing and getattr(existing, "name", "") == fingerprint:
        return
    
    # 计算下次触发时间
    min_minutes = proactive_config.get("min_interval_minutes", 30)
    max_minutes = proactive_config.get("max_interval_minutes", 120)
    min_minutes = max(1, min(10080, int(min_minutes)))
    max_minutes = max(min_minutes, min(10080, int(max_minutes)))
    interval_minutes = random.randint(min_minutes, max_minutes)
    
    from services.behavior_service import clock
    now = clock()
    next_run = now + timedelta(minutes=interval_minutes)
    
    # 检查安静时间
    quiet_start = proactive_config.get("quiet_hours_start", 23)
    quiet_end = proactive_config.get("quiet_hours_end", 7)
    
    current_hour = now.hour
    if _in_quiet(current_hour, quiet_start, quiet_end):
        # 安静时间内，推迟到安静时间结束
        next_run = now.replace(hour=quiet_end, minute=0, second=0)
        if next_run < now:
            next_run += timedelta(days=1)
    
    scheduler.add_job(
        _trigger_proactive,
        DateTrigger(run_date=next_run),
        id=job_id,
        args=[role_id],
        name=fingerprint,
        replace_existing=True
    )
    
    logger.info("", extra={"event": "proactive_scheduled", "role_ref": reference(role_id)})

async def _trigger_proactive(role_id: str):
    from routers.sync import WRITE_GATE
    async with WRITE_GATE:
        await _run_proactive(role_id)


async def _run_proactive(role_id: str):
    try:
        from services.auth_service import initialized
        from routers.ai_behavior import load_role
        role = load_role(role_id)
        config = (role or {}).get("proactive_config") or {}
        if not initialized() or not role or not config.get("enabled"):
            return
        from services.behavior_service import gate
        if gate(role_id, "proactive") != "ready":
            return
        if _event_callback:
            await _event_callback({"request_id": "proactive-" + role_id + "-" + str(int(datetime.now().timestamp() // 60)),
                "role_id": role_id, "event_type": "proactive", "content": "", "context": {}})
    finally:
        schedule_proactive_for_role(role_id)

# ========== 定时任务调度 ==========

def _init_scheduled_tasks():
    """初始化所有定时任务"""
    tasks_file = TASKS_DIR / "scheduled.json"
    if not tasks_file.exists():
        return
    
    with open(tasks_file, "r", encoding="utf-8") as f:
        tasks = json.load(f)
    
    changed = False
    from services.operation_service import status
    for task in tasks:
        if task.get("enabled", True):
            if (task["id"], task["trigger_time"]) in _active_tasks:
                continue
            state = status("event:task-" + task["id"] + "-" + task["trigger_time"])
            if state != "missing":
                # A crash between delivery and saving task state must not replay.
                _advance_task(task, state if state in ("completed", "failed") else "uncertain")
                changed = True
            if task.get("enabled", True):
                schedule_task(task)
    if changed:
        from routers.tasks import save_tasks
        save_tasks(tasks)


def _advance_task(task, outcome):
    task["last_status"] = outcome
    task["last_run"] = datetime.now().isoformat()
    if task.get("repeat") in ("daily", "weekly"):
        days = 1 if task["repeat"] == "daily" else 7
        next_time = datetime.fromisoformat(task["trigger_time"]) + timedelta(days=days)
        while next_time <= datetime.now(next_time.tzinfo):
            next_time += timedelta(days=days)
        task["trigger_time"] = next_time.isoformat()
    else:
        task["enabled"] = False

def schedule_task(task: Dict):
    """调度单个任务"""
    scheduler = get_scheduler()
    task_id = task.get("id")
    job_id = f"task_{task_id}"
    
    if not scheduler.running:
        return
    if not task.get("enabled", True):
        if scheduler.get_job(job_id):
            scheduler.remove_job(job_id)
        return
    trigger_time = task.get("trigger_time")
    if not trigger_time:
        return
    
    try:
        run_time = datetime.fromisoformat(trigger_time)
        from services.operation_service import database
        with database() as db:
            if db.execute("SELECT 1 FROM operations WHERE id=?", ("event:task-" + task_id + "-" + trigger_time,)).fetchone():
                return
        if scheduler.get_job(job_id):
            return
        
        scheduler.add_job(
            _trigger_task,
            DateTrigger(run_date=run_time),
            id=job_id,
            args=[task],
            misfire_grace_time=None,
            replace_existing=True
        )
        
        logger.info("", extra={"event": "task_scheduled"})
    except Exception:
        logger.exception("", extra={"event": "task_schedule_failed"})

async def _trigger_task(task: Dict):
    identity = (task["id"], task["trigger_time"])
    if identity in _active_tasks:
        return
    _active_tasks.add(identity)
    try:
        from routers.sync import WRITE_GATE
        async with WRITE_GATE:
            await _run_task(task)
    finally:
        _active_tasks.discard(identity)


async def _run_task(task: Dict):
    from routers.tasks import load_tasks, save_tasks
    from services.auth_service import initialized
    if not initialized():
        return
    current = next((t for t in load_tasks() if t["id"] == task["id"]), None)
    if not current or not current.get("enabled", True):
        return
    if current.get("trigger_time") != task.get("trigger_time"):
        return
    from services.settings_service import load_settings
    if quiet_now():
        from services.behavior_service import clock
        # Check the union of legacy and new quiet windows, including day windows.
        now = clock()
        next_time = now + timedelta(minutes=5)
        get_scheduler().add_job(_trigger_task, DateTrigger(run_date=next_time), args=[current],
                                id="task_" + current["id"], replace_existing=True, misfire_grace_time=None)
        return
    if _event_callback:
        outcome = "uncertain"
        try:
            result = await _event_callback({"request_id": "task-" + current["id"] + "-" + current["trigger_time"],
                "role_id": current["role_id"], "event_type": "task",
                "content": current.get("ai_prompt") or current.get("message", ""),
                "context": {"task_id": current["id"], "chat_id": current.get("chat_id", current["role_id"])}})
            from services.operation_service import failure_state
            outcome = "completed" if result and result.success else failure_state(result.error if result else "未确认")
        finally:
            tasks = load_tasks()
            for value in tasks:
                if value["id"] == current["id"]:
                    _advance_task(value, outcome)
            save_tasks(tasks)

# ========== 朋友圈 AI 调度 ==========

def _init_moment_jobs():
    """初始化朋友圈 AI 调度"""
    scheduler = get_scheduler()
    
    # 每 2-4 小时检查一次是否有 AI 要发朋友圈
    scheduler.add_job(
        _check_moment_posts,
        IntervalTrigger(hours=3),
        id="moment_check",
        replace_existing=True
    )
    
    logger.info("", extra={"event": "moment_check_scheduled"})

async def _check_moment_posts():
    from routers.sync import WRITE_GATE
    async with WRITE_GATE:
        await _run_moment_posts()


async def _run_moment_posts():
    from services.auth_service import initialized
    if not initialized() or quiet_now():
        return
    """检查是否有 AI 要发朋友圈"""
    global _event_callback
    
    if not ROLES_DIR.exists() or not _event_callback:
        return
    
    roles = []
    for role_dir in ROLES_DIR.iterdir():
        if role_dir.is_dir():
            profile_file = role_dir / "profile.json"
            if profile_file.exists():
                with open(profile_file, "r", encoding="utf-8") as f:
                    role = json.load(f)
                    if not role.get("deleted"):
                        roles.append(role)
    
    if not roles:
        return
    
    # 随机选择一个角色发朋友圈（30% 概率）
    if random.random() < 0.3:
        role = random.choice(roles)
        from services import behavior_service as autonomy
        if autonomy.gate(role["id"], "moment") != "ready":
            return
        await _event_callback({
            "request_id": "moment-" + role["id"] + "-" + str(int(datetime.now().timestamp() // 10800)),
            "role_id": role.get("id"),
            "event_type": "moment",
            "content": "",
            "context": {}
        })
        logger.info("", extra={"event": "moment_triggered", "role_ref": reference(role.get('id'))})

# ========== 状态查询 ==========

def get_scheduler_status() -> Dict:
    """获取调度器状态"""
    scheduler = get_scheduler()
    jobs = scheduler.get_jobs()
    
    return {
        "running": scheduler.running,
        "job_count": len(jobs),
        "jobs": [
            {
                "id": job.id,
                "next_run": job.next_run_time.isoformat() if job.next_run_time else None
            }
            for job in jobs
        ]
    }


def _in_quiet(hour, start, end):
    if start == end:
        return False
    return start <= hour < end if start < end else hour >= start or hour < end


async def _refresh_jobs():
    from routers.sync import WRITE_GATE
    async with WRITE_GATE:
        _init_proactive_jobs()
        _init_scheduled_tasks()
        # Local rules only; advancing life never spends a provider call.
        from services.behavior_service import life
        from routers.ai_behavior import load_role
        for path in ROLES_DIR.glob("*/profile.json"):
            if load_role(path.parent.name):
                life(path.parent.name)


async def _check_moment_interactions():
    from routers.sync import WRITE_GATE
    async with WRITE_GATE:
        await _run_moment_interactions()


async def _run_moment_interactions():
    from services.auth_service import initialized
    from routers.moments import load_moments, save_moments
    from routers.ai_behavior import load_role
    from services.operation_service import claim, finish
    from fastapi import HTTPException
    if not initialized() or not _event_callback or quiet_now():
        return
    roles = [load_role(p.name) for p in ROLES_DIR.iterdir() if p.is_dir()] if ROLES_DIR.exists() else []
    roles = [r for r in roles if r]
    posts = load_moments()[:20]
    if not roles or not posts:
        return
    role = random.choice(roles)
    from services import behavior_service as autonomy
    if autonomy.gate(role["id"], "like") != "ready":
        return
    # Respond to new user comments independently of the post's one-time like.
    for item in posts:
        for comment in item.get("comments", []):
            if comment.get("author_id") != "me" or comment.get("reply_to_id") not in (None, role["id"]):
                continue
            reply_id = "reply-" + hashlib.sha256((role["id"] + ":" + comment["id"]).encode()).hexdigest()
            from services.operation_service import status
            if status("event:" + reply_id) != "missing":
                continue
            if autonomy.gate(role["id"], "comment") != "ready":
                continue
            await _event_callback({"request_id": reply_id, "role_id": role["id"], "event_type": "comment", "content": "",
                "context": {"post_id": item["id"], "post_content": item["content"], "post_author": item["author_name"],
                    "reply_to": comment["content"], "reply_to_id": "me", "reply_to_name": comment["author_name"]}})
            return
    eligible = [p for p in posts if p["author_id"] != role["id"] and
                (datetime.now() - datetime.fromisoformat(p["created_at"]).replace(tzinfo=None)).total_seconds() < 86400]
    if not eligible:
        return
    post = random.choice(eligible)
    identity = "interaction-" + hashlib.sha256((role["id"] + ":" + post["id"]).encode()).hexdigest()
    try:
        claim(identity, {"role": role["id"], "post": post["id"]})
    except HTTPException:
        return
    # Rules decide most interactions without a model call.
    if random.random() < 0.6:
        if autonomy.gate(role["id"], "like", identity, reserve=True) != "ready":
            finish(identity)
            return
        latest = load_moments()
        for value in latest:
            if value["id"] == post["id"] and not any(item["id"] == role["id"] for item in value.get("liked_by", [])):
                value.setdefault("liked_by", []).append({"id": role["id"], "name": role["name"]})
        save_moments(latest)
    else:
        if autonomy.gate(role["id"], "comment") != "ready":
            finish(identity)
            return
        await _event_callback({"request_id": identity, "role_id": role["id"], "event_type": "comment",
            "content": "", "context": {"post_id": post["id"], "post_content": post["content"], "post_author": post["author_name"]}})
    finish(identity)


def quiet_now():
    from services.settings_service import load_settings
    config = load_settings()
    from services import behavior_service as autonomy
    p, hour = autonomy.policy(), autonomy.clock().hour
    return ((config.get("quiet_enabled", False) and _in_quiet(hour, config.get("quiet_start", 23), config.get("quiet_end", 7)))
            or (p["quiet_enabled"] and _in_quiet(hour, p["quiet_start"], p["quiet_end"])))
