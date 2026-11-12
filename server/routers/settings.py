from fastapi import Request
from services.resource_service import resource_response
"""
设置路由
管理全局配置的 API 端点
"""
from typing import Optional
from pydantic import BaseModel, Field
from fastapi import APIRouter

router = APIRouter()

# 导入设置服务
from services import settings_service

class SettingsUpdate(BaseModel):
    ai_api_url: Optional[str] = None
    ai_api_key: Optional[str] = None
    ai_model: Optional[str] = None
    intent_enabled: Optional[bool] = None
    intent_api_url: Optional[str] = None
    intent_api_key: Optional[str] = None
    intent_model: Optional[str] = None
    vision_enabled: Optional[bool] = None
    vision_api_url: Optional[str] = None
    vision_api_key: Optional[str] = None
    vision_model: Optional[str] = None
    message_wait_seconds: Optional[int] = Field(default=None, ge=0, le=60)
    base_prompt: Optional[str] = None
    group_prompt: Optional[str] = None
    memory_prompt: Optional[str] = None
    quiet_enabled: Optional[bool] = None
    quiet_start: Optional[int] = None
    quiet_end: Optional[int] = None
    host: Optional[str] = None
    port: Optional[int] = None

@router.get("/settings")
async def get_settings():
    """获取全局设置"""
    settings = settings_service.load_settings()
    for field in ("ai_api_key", "intent_api_key", "vision_api_key"):
        settings[field + "_configured"] = bool(settings.pop(field, ""))
    for prefix in ('ai', 'intent', 'vision'):
        selected = settings_service.provider_config(settings_service.load_settings(), prefix)
        settings[prefix + '_ready'] = bool(selected['api_url'] and selected['api_key'])
        settings.pop(prefix + '_credential_origin', None)
    settings.pop("role_api_credentials", None)
    settings.pop("tts_credentials", None)
    return {"settings": settings}

@router.put("/settings")
async def update_settings(update: SettingsUpdate):
    """更新全局设置"""
    updates = update.model_dump(exclude_none=True)
    for field in ("ai_api_url", "intent_api_url", "vision_api_url"):
        if updates.get(field):
            from services.role_api_service import validate_url
            validate_url(updates[field])
    for field in ("quiet_start", "quiet_end"):
        if field in updates and not 0 <= updates[field] <= 23:
            from fastapi import HTTPException
            raise HTTPException(422, "安静时段须为 0 至 23 点")

    if updates:
        success = settings_service.save_settings(updates)
        if success:
            return {"success": True, "message": "Settings updated"}
        else:
            from fastapi import HTTPException
            raise HTTPException(500, "设置保存失败，请手动重试")
    
    return {"success": True, "message": "No changes"}


@router.post("/settings/migrate")
async def migrate_settings(update: SettingsUpdate):
    """Import legacy device defaults only where this server has no value."""
    current = settings_service.load_settings()
    proposed = update.model_dump(exclude_none=True)
    missing = {}
    for prefix in ("ai", "intent", "vision"):
        provider_empty = not current.get(prefix + "_api_url") and not current.get(prefix + "_api_key")
        for suffix in ("api_url", "api_key", "model"):
            field = prefix + "_" + suffix
            value = proposed.pop(field, None)
            if provider_empty and value:
                missing[field] = value
    for field, value in proposed.items():
        if field in ("host", "port") or value in (None, ""):
            continue
        if field not in current or current[field] in (None, ""):
            missing[field] = value
    return await update_settings(SettingsUpdate(**missing))

@router.get("/settings/ai")
async def get_ai_settings():
    """获取 AI API 配置（不含敏感信息）"""
    config = settings_service.get_ai_config()
    config["api_key_configured"] = bool(config.pop("api_key", ""))
    return config

@router.get("/settings/models")
async def get_available_models(purpose: str = 'chat'):
    """获取 API 可用模型列表"""
    import httpx
    
    if purpose not in ('chat', 'intent', 'vision'):
        from fastapi import HTTPException
        raise HTTPException(422, '无效 API 用途')
    config = settings_service.get_ai_config(purpose)
    api_url = config.get("api_url", "")
    api_key = config.get("api_key", "")
    
    if not api_url or not api_key:
        return {"success": False, "error": "API 未配置", "models": []}
    
    # 尝试获取模型列表
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            # 构建 models 端点 URL
            from services.ai_service import models_endpoint
            models_url = models_endpoint(api_url)
            
            response = await client.get(
                models_url,
                headers={"Authorization": f"Bearer {api_key}"}
            )
            
            if response.status_code == 200:
                data = response.json()
                models = data.get("data", [])
                # 提取模型 ID 列表
                model_ids = [m.get("id") for m in models if m.get("id")]
                # 过滤常见的可用模型
                return {"success": True, "models": list(dict.fromkeys(model_ids))}
            else:
                return {"success": False, "error": f"HTTP {response.status_code}", "models": []}
    except Exception:
        from services.logging_service import get_logger
        get_logger("settings").exception("", extra={"event": "model_list_failed"})
        return {"success": False, "error": "模型列表获取失败，请手动重试", "models": []}

# 头像上传
from fastapi import UploadFile, File
from pathlib import Path
import shutil
import uuid

from services.paths_service import DATA_DIR
AVATARS_DIR = DATA_DIR / "avatars"

@router.post("/settings/avatar")
async def upload_avatar(file: UploadFile = File(...)):
    """上传用户头像"""
    from services.upload_service import image
    content, ext = await image(file)
    AVATARS_DIR.mkdir(parents=True, exist_ok=True)
    
    # 生成唯一文件名
    filename = f"user_avatar_{uuid.uuid4().hex[:8]}.{ext}"
    filepath = AVATARS_DIR / filename
    
    # 保存文件
    with open(filepath, "xb") as f:
        f.write(content)
    
    # 返回相对路径
    return {
        "success": True,
        "filename": filename,
        "path": f"/api/avatars/{filename}"
    }

@router.get("/avatars/{filename}")
async def get_avatar(filename: str, request: Request):
    """获取头像文件"""
    from fastapi.responses import FileResponse
    filepath = AVATARS_DIR / filename
    if filepath.exists():
        return resource_response(filepath, request)
    return {"error": "not found"}


@router.post("/settings/images")
async def upload_display_image(file: UploadFile = File(...)):
    """Persistent authenticated resources shared by every device."""
    result = await upload_avatar(file)
    return {"path": result["path"]}

