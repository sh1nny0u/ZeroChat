"""Administrator management and role/chat scoped retrieval."""
from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from services import hybrid_memory_service as memory, sync_service

router = APIRouter()


class Write(BaseModel):
    entry: memory.Entry
    base_version: str | None = None
    operation_id: str = Field(min_length=8, max_length=128)


class Decision(BaseModel):
    base_version: str
    operation_id: str = Field(min_length=8, max_length=128)


@router.get("/memory/entries")
async def listing(scope: str | None = None, owner_id: str | None = None, category: str | None = None,
                  status: str | None = None, q: str = Query(default="", max_length=2000),
                  offset: int = Query(default=0, ge=0), limit: int = Query(default=50, ge=1, le=100)):
    def run():
        memory.ensure_index()
        rows = [e for e in memory.entries_from_index() if not e.get("deleted")
                and (scope is None or e["scope"] == scope) and (owner_id is None or e["owner_id"] == owner_id)
                and (category is None or e["category"] == category) and (status is None or e["status"] == status)
                and (not q or q.casefold() in e["content"].casefold())]
        rows.sort(key=lambda e: e["updated_at"], reverse=True)
        selected = rows[offset:offset + limit]
        for entry in selected:
            entry["sync_version"] = sync_service.version("memory_entry", entry["id"])
        return {"entries": selected, "total": len(rows), "has_more": offset + limit < len(rows),
                "policy": memory.policy(), "policy_version": sync_service.version("memory_policy", "global")}
    return await run_in_threadpool(run)


@router.put("/memory/entries/{key}")
async def save(key: str, body: Write):
    if body.entry.id != key:
        raise HTTPException(422, "记忆编号不匹配")
    return await run_in_threadpool(memory.save, body.entry.model_dump(), body.base_version, body.operation_id)


@router.delete("/memory/entries/{key}")
async def delete(key: str, body: Decision):
    sync_service.identity(key)
    return await run_in_threadpool(sync_service.mutate, {"kind": "memory_entry", "id": key, "payload": {},
        "base_version": body.base_version, "operation_id": body.operation_id, "deleted": True})


@router.post("/memory/retrieve")
async def retrieve(body: dict):
    role, chat, query = body.get("role_id"), body.get("chat_id"), body.get("query", "")
    if not isinstance(query, str) or len(query) > 2000 or not isinstance(role, str) or (chat is not None and not isinstance(chat, str)):
        raise HTTPException(422, "检索参数无效")
    return await run_in_threadpool(memory.retrieve, role, query, chat)


@router.post("/memory/entries/{key}/confirm")
async def confirm(key: str, body: Decision):
    return await run_in_threadpool(memory.confirm, key, body.base_version, body.operation_id)


@router.post("/memory/rebuild")
async def rebuild():
    await run_in_threadpool(memory.ensure_index, True)
    return {"success": True, "message": "本地索引已从有效记忆重建"}


@router.get("/memory/status")
async def status():
    def run():
        try:
            memory.index.encoder()
            vector = True
        except (ValueError, OSError, ImportError, RuntimeError):
            vector = False
        return {"vector_available": vector, "model": memory.index.MODEL, "device": "CPU",
                "policy": memory.policy(), "policy_version": sync_service.version("memory_policy", "global")}
    return await run_in_threadpool(run)
