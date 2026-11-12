"""Authenticated life/adaptation view; changes use the existing versioned sync."""
from fastapi import APIRouter
from starlette.concurrency import run_in_threadpool
from services import behavior_service as behavior, sync_service

router = APIRouter()


@router.get("/behavior/policy")
async def policy():
    sync_service.reconcile()
    return {"policy": behavior.policy(), "version": sync_service.version("behavior_policy", "global")}


@router.get("/behavior/roles/{role_id}")
async def role_status(role_id: str):
    sync_service.reconcile()
    return await run_in_threadpool(behavior.status, role_id)
