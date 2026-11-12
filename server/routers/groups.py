"""Backend-owned group turn selection and indexed history."""
import asyncio
import json
import random
from datetime import datetime
from fastapi import APIRouter, HTTPException, Header
from starlette.concurrency import run_in_threadpool
from pydantic import BaseModel, Field
from services.paths_service import DATA_DIR
from services import history_service, operation_service
from services.event_service import message
from services.sync_service import local_mutation, write_json

router = APIRouter()
_locks = {}


class Group(BaseModel):
    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    name: str = Field(max_length=200)
    member_ids: list[str] = Field(max_length=30)
    ai_reply_probability: float = Field(default=0.6, ge=0, le=1)
    allow_ai_to_ai_interaction: bool = True
    max_consecutive_speaks: int = Field(default=2, ge=1, le=5)
    cooldown_seconds: int = Field(default=5, ge=0, le=3600)
    max_replies_per_minute: int = Field(default=10, ge=1, le=30)
    owner_id: str = "user"
    core_memory: list[str] = Field(default_factory=list, max_length=100)
    summary_every_n_rounds: int = Field(default=20, ge=1, le=1000)


class Turn(BaseModel):
    request_id: str = Field(min_length=8, max_length=128)
    content: str = Field(max_length=100000)
    quote_id: str | None = Field(default=None, max_length=200)
    quote_content: str | None = Field(default=None, max_length=1000)


def directory(group_id):
    if not group_id.replace("_", "").replace("-", "").isalnum():
        raise HTTPException(422, "无效群聊编号")
    return DATA_DIR / "groups" / group_id


def load(group_id):
    path = directory(group_id) / "profile.json"
    if not path.exists():
        raise HTTPException(404, "群聊不存在，请同步群聊后重试")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("deleted"):
        raise HTTPException(404, "群聊已删除")
    return Group(**data)


@router.put("/groups/{group_id}")
@local_mutation
async def save(group_id: str, body: Group, x_base_version: str | None = Header(default=None)):
    from routers.ai_behavior import load_role
    if body.id != group_id or not body.member_ids or any(load_role(r) is None for r in body.member_ids):
        raise HTTPException(422, "群聊编号或成员无效")
    root = directory(group_id)
    path = root / "profile.json"
    if path.exists():
        from services import sync_service
        sync_service.check_version("group", group_id, x_base_version, DATA_DIR, json.loads(path.read_text(encoding="utf-8")))
    root.mkdir(parents=True, exist_ok=True)
    write_json(root / 'profile.json', body.model_dump())
    return {"success": True}


@router.get("/groups/{group_id}/chats/messages")
async def history(group_id: str, limit: int = 50, before: str = None, after: int = None):
    load(group_id)
    if after is not None and after < 0:
        raise HTTPException(422, "无效分页参数")
    try:
        return await run_in_threadpool(history_service.page, directory(group_id) / "chats", limit, before, after)
    except ValueError:
        raise HTTPException(422, "无效分页参数")


@router.post("/groups/{group_id}/chats/sync")
async def sync_history(group_id: str, body: dict):
    load(group_id)
    from routers.roles import ChatMessagesSync
    try:
        messages = ChatMessagesSync(**body)
        if len(messages.messages) > 100:
            raise ValueError("Batch too large")
        return await run_in_threadpool(history_service.append, directory(group_id) / "chats",
                                       [row.model_dump() for row in messages.messages])
    except ValueError:
        raise HTTPException(422, "历史消息无法可靠导入，原记录保留")


@router.get("/groups/{group_id}")
async def get_group(group_id: str):
    return load(group_id)


@router.delete("/groups/{group_id}/chats/messages")
async def clear_history(group_id: str):
    load(group_id)
    async with _locks.setdefault(group_id, asyncio.Lock()):
        return await run_in_threadpool(history_service.remove, directory(group_id) / "chats")


@router.delete("/groups/{group_id}/chats/messages/{message_id}")
async def delete_message(group_id: str, message_id: str):
    load(group_id)
    async with _locks.setdefault(group_id, asyncio.Lock()):
        return await run_in_threadpool(history_service.remove, directory(group_id) / "chats", message_id)


@router.post("/groups/{group_id}/turn")
async def turn(group_id: str, body: Turn):
    group = load(group_id)
    key = "group:" + body.request_id
    rows = []
    async with _locks.setdefault(group_id, asyncio.Lock()):
        operation_service.claim(key, {"group_id": group_id, **body.model_dump()})
        try:
            return await _run_turn(group_id, group, body, key, rows)
        except BaseException:
            operation_service.finish(key, "uncertain")
            raise


async def _run_turn(group_id, group, body, key, rows):
    from routers.ai_behavior import load_role
    from services.ai_service import generate_with_role, load_config, call_ai
    root = directory(group_id)
    state_file = root / "behavior.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    now = datetime.now().timestamp()
    user = message(body.request_id + "_user", "me", body.content)
    user.update(quote_id=body.quote_id, quote_content=body.quote_content)
    if now - state.get("last_reply", 0) < group.cooldown_seconds:
        history_service.append(root / "chats", [user])
        operation_service.finish(key)
        return {"success": True, "messages": [user]}
    context_limit = min(200, max((load_role(r) or {}).get("max_context_rounds", 10) * 2 for r in group.member_ids))
    history = history_service.page(root / "chats", limit=max(1, context_limit))["messages"]
    context = [{"role": "user" if m["sender_id"] == "me" else "assistant",
                "content": ("" if m["sender_id"] == "me" else m["sender_id"] + ": ") + m["content"]} for m in history]
    current = body.content
    if body.quote_content:
        current = "引用：" + body.quote_content + "\n" + current
    memory_file = root / "memory.json"
    memory = json.loads(memory_file.read_text(encoding="utf-8")) if memory_file.exists() else {}
    extra = "这是群聊，只能使用本群上下文，不要引用其他会话的私密记忆。\n" + load_config().get("group_prompt", "")
    last_speaker = None
    counts = {}
    rounds = 3 if group.allow_ai_to_ai_interaction else 1
    minute_count = state.get("count", 0) if state.get("minute") == int(now // 60) else 0
    for round_index in range(rounds):
        candidates = [r for r in group.member_ids if r != last_speaker and counts.get(r, 0) < group.max_consecutive_speaks]
        selected = [r for r in candidates if random.random() < group.ai_reply_probability or "@" + (load_role(r) or {}).get("name", r) in current]
        random.shuffle(selected)
        for role_id in selected[:3]:
            if minute_count >= group.max_replies_per_minute:
                break
            role = load_role(role_id)
            if not role:
                continue
            from services.hybrid_memory_service import context as memory_context
            from services import behavior_service as autonomy
            role = {**role, "_behavior_context": autonomy.context(role_id, group_id)}
            if round_index > 0:
                identity = body.request_id + f":{round_index}:{role_id}"
                if autonomy.gate(role_id, "group", identity, reserve=True) != "ready":
                    continue
                with autonomy.optional(role_id, "group", identity):
                    result = await generate_with_role(role, current, history=context,
                        extra_context=extra + "\n" + memory_context(role_id, current, group_id))
            else:
                # The user-initiated round is normal chat, even at zero optional budget.
                result = await generate_with_role(role, current, history=context,
                    extra_context=extra + "\n" + memory_context(role_id, current, group_id))
            if not result["success"]:
                if round_index > 0:
                    from services.logging_service import get_logger
                    get_logger("behavior").warning("", extra={"event": "group_followup_paused"})
                    continue
                operation_service.finish(key, "completed" if rows else operation_service.failure_state(result["error"]))
                return {"success": False, "error": result["error"], "messages": rows}
            if round_index > 0 and autonomy._rule(role_id, "group") != "ready":
                continue
            if not rows:
                history_service.append(root / "chats", [user])
                rows.append(user)
            from services.delivery_service import replies
            from services.tts_service import prepare, deliver
            result["content"], voice_requested = prepare(result["content"])
            reply_rows = replies(body.request_id + f"_reply_{len(rows)}", role_id, result["content"])
            await deliver(root / "chats", reply_rows, voice_requested)
            rows.extend(reply_rows)
            minute_count += 1
            state_file.write_text(json.dumps({"last_reply": now, "minute": int(now // 60), "count": minute_count}))
            counts[role_id] = counts.get(role_id, 0) + 1
            last_speaker, current = role_id, result["content"]
            context.append({"role": "assistant", "content": role["name"] + ": " + current})
        if random.random() > 0.3 / (round_index + 1):
            break
    if not rows:
        history_service.append(root / "chats", [user])
        rows.append(user)
    operation_service.finish(key)
    memory["rounds"] = memory.get("rounds", 0) + 1
    if memory["rounds"] >= group.summary_every_n_rounds:
        try:
            from services import behavior_service as autonomy
            result = {"success": False}
            if autonomy.gate(group.member_ids[0], "memory") == "ready":
                with autonomy.optional(group.member_ids[0], "memory", body.request_id + ":summary"):
                    result = await call_ai([{"role": "system", "content": load_config().get("memory_prompt") or "整理本群核心记忆，保留可靠事实，简短输出。"},
                        {"role": "user", "content": extra + "\n" + json.dumps(context, ensure_ascii=False)}], role_id=group.member_ids[0])
            if result["success"]:
                from services.hybrid_memory_service import propose
                propose(group.member_ids[0], result["content"], "群聊自动总结，需用户确认", group_id)
                memory.update(rounds=0)
        except Exception:
            from services.logging_service import get_logger
            get_logger("memory").exception("", extra={"event": "group_summary_failed"})
    try:
        memory_file.write_text(json.dumps(memory, ensure_ascii=False), encoding="utf-8")
    except OSError:
        from services.logging_service import get_logger
        get_logger("memory").exception("", extra={"event": "group_summary_save_failed"})
    return {"success": True, "messages": rows}
