"""Authenticated portable role API. Decisions require an explicit preview."""
from typing import Literal
from fastapi import APIRouter
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from services import role_share_service as service

router = APIRouter()


class Export(BaseModel):
    include_attachment: bool = False


class Code(BaseModel):
    code: str = Field(max_length=service.MAX_CODE)


class Import(Code):
    mode: Literal["create", "copy", "update"] = "create"
    operation_id: str = Field(pattern=r"^[A-Za-z0-9_-]{8,128}$")
    target_id: str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]{1,128}$")
    base_version: str | None = Field(default=None, max_length=64)


@router.post("/roles/{role_id}/share/export")
async def export(role_id: str, body: Export):
    return await run_in_threadpool(service.export, role_id, body.include_attachment)


@router.post("/share/preview")
async def preview(body: Code):
    return await run_in_threadpool(service.preview, body.code)


@router.post("/share/import")
async def import_role(body: Import):
    return await run_in_threadpool(service.import_role, body.model_dump())
