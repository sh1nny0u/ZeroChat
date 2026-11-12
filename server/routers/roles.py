from services.resource_service import resource_response, version
"""
角色管理路由
"""
import json
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
from fastapi import APIRouter, HTTPException, Request, Header
from services import history_service
from services.sync_service import local_mutation
from starlette.concurrency import run_in_threadpool
from services.logging_service import get_logger, reference
import time

logger = get_logger("sync")

router = APIRouter()


class RoleApiUpdate(BaseModel):
    revision: Optional[str] = Field(default=None, max_length=64)
    api_url: Optional[str] = Field(default=None, max_length=2048)
    api_key: Optional[str] = Field(default=None, max_length=8192)
    model: Optional[str] = Field(default=None, max_length=256)


@router.get("/roles/{role_id}/chat-api")
async def get_role_api(role_id: str):
    if not load_role(role_id):
        raise HTTPException(404, "角色不存在")
    from services import role_api_service
    return role_api_service.read(role_id)


@router.put("/roles/{role_id}/chat-api")
async def put_role_api(role_id: str, update: RoleApiUpdate):
    if not load_role(role_id):
        raise HTTPException(404, "角色不存在")
    from services import role_api_service
    return role_api_service.save(role_id, update.model_dump())

from services.paths_service import DATA_DIR
ROLES_DIR = DATA_DIR / "roles"

class ProactiveConfig(BaseModel):
    """主动消息配置"""
    enabled: bool = False
    min_interval_minutes: int = 30
    max_interval_minutes: int = 120
    trigger_prompt: str = ""
    quiet_hours_start: int = 23  # 23:00
    quiet_hours_end: int = 7    # 07:00
    next_trigger_time: Optional[str] = None

class PersonalityTraits(BaseModel):
    """人格特质"""
    openness: int = 50          # 开放性 0-100
    conscientiousness: int = 50 # 尽责性
    extraversion: int = 50      # 外向性
    agreeableness: int = 50     # 宜人性
    neuroticism: int = 50       # 神经质

class RoleCreate(BaseModel):
    """创建角色"""
    id: str
    name: str
    avatar_url: Optional[str] = ""
    
    # 人设与提示词
    persona: Optional[str] = ""         # 角色人设描述
    system_prompt: Optional[str] = ""   # 系统提示词
    attached_json_content: Optional[str] = None
    greeting: Optional[str] = ""        # 首次对话问候语
    description: Optional[str] = ""     # 简短描述
    
    # 核心记忆
    core_memory: Optional[List[str]] = []
    
    # 人格配置
    personality: Optional[PersonalityTraits] = None
    
    # 主动消息配置
    proactive_config: Optional[ProactiveConfig] = None
    
    # AI 参数
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    frequency_penalty: Optional[float] = None
    presence_penalty: Optional[float] = None
    max_context_rounds: Optional[int] = None
    allow_web_search: Optional[bool] = None
    summary_every_n_rounds: int = Field(default=20, ge=1, le=1000)
    
    # 扩展元数据
    tags: Optional[List[str]] = []
    metadata: Optional[Dict[str, Any]] = {}

class RoleUpdate(BaseModel):
    """更新角色"""
    name: Optional[str] = None
    avatar_url: Optional[str] = None
    persona: Optional[str] = None
    system_prompt: Optional[str] = None
    attached_json_content: Optional[str] = None
    greeting: Optional[str] = None
    description: Optional[str] = None
    core_memory: Optional[List[str]] = None
    personality: Optional[PersonalityTraits] = None
    proactive_config: Optional[ProactiveConfig] = None
    # AI 参数
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    frequency_penalty: Optional[float] = None
    presence_penalty: Optional[float] = None
    max_context_rounds: Optional[int] = None
    allow_web_search: Optional[bool] = None
    summary_every_n_rounds: Optional[int] = Field(default=None, ge=1, le=1000)
    tags: Optional[List[str]] = None
    metadata: Optional[Dict[str, Any]] = None

class MemoryUpdate(BaseModel):
    """记忆更新"""
    core_memory: Optional[str] = None
    short_term: Optional[List[str]] = None

def get_role_dir(role_id: str) -> Path:
    """获取角色目录，自动创建完整目录结构"""
    if not role_id.replace("_", "").replace("-", "").isalnum() or len(role_id) > 128:
        raise HTTPException(422, "无效角色编号")
    role_dir = ROLES_DIR / role_id
    role_dir.mkdir(parents=True, exist_ok=True)
    
    # 创建所有子目录
    subdirs = ["assets", "chats", "emojis", "moments", "backgrounds"]
    for subdir in subdirs:
        (role_dir / subdir).mkdir(exist_ok=True)
    
    # 创建情绪表情包子目录
    emotions = ["happy", "sad", "angry", "surprised", "love", "confused", "tired", "excited"]
    for emotion in emotions:
        (role_dir / "emojis" / emotion).mkdir(exist_ok=True)
    
    # 创建初始 JSON 文件（如不存在）
    if not (role_dir / "memory.json").exists():
        with open(role_dir / "memory.json", "w", encoding="utf-8") as f:
            json.dump({"short_term": [], "core_memory": [], "message_count_since_summary": 0}, f)
    
    if not (role_dir / "chats" / "messages.json").exists():
        with open(role_dir / "chats" / "messages.json", "w", encoding="utf-8") as f:
            json.dump({"messages": []}, f)
    
    if not (role_dir / "moments" / "posts.json").exists():
        with open(role_dir / "moments" / "posts.json", "w", encoding="utf-8") as f:
            json.dump({"posts": []}, f)
    
    return role_dir

def load_role(role_id: str) -> Optional[Dict]:
    if not role_id.replace("_", "").replace("-", "").isalnum() or len(role_id) > 128:
        raise HTTPException(422, "无效角色编号")
    profile_file = ROLES_DIR / role_id / "profile.json"
    if profile_file.exists():
        with open(profile_file, "r", encoding="utf-8") as f:
            data = json.load(f)
            return None if data.get("deleted") else data
    return None

def save_role(role_id: str, data: Dict):
    profile_file = get_role_dir(role_id) / "profile.json"
    data["updated_at"] = datetime.now().isoformat()
    from services.sync_service import write_json
    write_json(profile_file, data)

@router.get("/roles")
async def list_roles():
    """获取所有角色"""
    roles = []
    if ROLES_DIR.exists():
        for role_dir in ROLES_DIR.iterdir():
            if role_dir.is_dir():
                role = load_role(role_dir.name)
                if role:
                    from services import sync_service
                    role["sync_version"] = sync_service.version("role", role["id"], ROLES_DIR.parent, role)
                    roles.append(sync_service.public(role))
    return {"roles": roles}

@router.get("/roles/{role_id}")
async def get_role(role_id: str):
    """获取角色详情"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    from services.sync_service import public
    return public(role)

@router.post("/roles")
@local_mutation
async def create_role(role: RoleCreate, x_base_version: Optional[str] = Header(default=None)):
    """创建或更新角色（upsert）"""
    existing = load_role(role.id)
    path = ROLES_DIR / role.id / "profile.json"
    if not existing and path.exists():
        raise HTTPException(409, "此编号已删除，请在数据同步页处理或新建独立角色")
    
    if existing:
        from services import sync_service
        sync_service.check_version("role", role.id, x_base_version, ROLES_DIR.parent, existing)
        # 更新现有角色
        logger.info("", extra={"event": "role_update_started", "role_ref": reference(role.id)})
        for key, value in role.model_dump(exclude_none=True).items():
            if key != 'id' and value is not None:
                if key == "metadata":
                    value = {**(existing.get("metadata") or {}), **value}
                existing[key] = value
        save_role(role.id, existing)
        from services.scheduler_service import schedule_proactive_for_role
        schedule_proactive_for_role(role.id)
        logger.info("", extra={"event": "role_updated", "role_ref": reference(role.id)})
        return existing
    
    # 创建新角色
    logger.info("", extra={"event": "role_create_started", "role_ref": reference(role.id)})
    data = {
        "id": role.id,
        "name": role.name,
        "avatar_url": role.avatar_url or "",
        "persona": role.persona or "",
        "system_prompt": role.system_prompt or "",
        "greeting": role.greeting or "",
        "description": role.description or "",
        "core_memory": role.core_memory or [],
        "personality": role.personality.model_dump() if role.personality else {
            "openness": 50, "conscientiousness": 50, "extraversion": 50,
            "agreeableness": 50, "neuroticism": 50
        },
        "proactive_config": role.proactive_config.model_dump() if role.proactive_config else {
            "enabled": False, "min_interval_minutes": 30, "max_interval_minutes": 120,
            "trigger_prompt": "", "quiet_hours_start": 23, "quiet_hours_end": 7,
            "next_trigger_time": None
        },
        "tags": role.tags or [],
        "metadata": role.metadata or {},
        "created_at": datetime.now().isoformat()
    }
    data.update(role.model_dump(exclude_none=True, exclude={"personality", "proactive_config"}))
    save_role(role.id, data)
    from services.scheduler_service import schedule_proactive_for_role
    schedule_proactive_for_role(role.id)
    logger.info("", extra={"event": "role_created", "role_ref": reference(role.id)})
    return data

@router.put("/roles/{role_id}")
@local_mutation
async def update_role(role_id: str, update: RoleUpdate, x_base_version: Optional[str] = Header(default=None)):
    """更新角色"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    from services import sync_service
    sync_service.check_version("role", role_id, x_base_version, ROLES_DIR.parent, role)
    for key, value in update.model_dump(exclude_none=True).items():
        if key == "metadata":
            value = {**(role.get("metadata") or {}), **value}
        role[key] = value
    
    save_role(role_id, role)
    from services.scheduler_service import get_scheduler, schedule_proactive_for_role
    scheduler = get_scheduler()
    if scheduler.get_job("proactive_" + role_id):
        scheduler.remove_job("proactive_" + role_id)
    schedule_proactive_for_role(role_id)
    return role

@router.delete("/roles/{role_id}")
@local_mutation
async def delete_role(role_id: str, x_base_version: Optional[str] = Header(default=None)):
    """删除角色"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(404, "角色不存在")
    from services import sync_service
    sync_service.check_version("role", role_id, x_base_version, ROLES_DIR.parent, role)
    save_role(role_id, {**role, "deleted": True})
    return {"success": True}

# ========== 记忆管理 ==========

def load_memory(role_id: str) -> Dict:
    memory_file = get_role_dir(role_id) / "memory.json"
    if memory_file.exists():
        with open(memory_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {"core_memory": "", "short_term": []}

def save_memory(role_id: str, memory: Dict):
    memory_file = get_role_dir(role_id) / "memory.json"
    from services.sync_service import write_json
    write_json(memory_file, memory)

@router.get("/roles/{role_id}/memory")
async def get_memory(role_id: str):
    """获取角色记忆"""
    return load_memory(role_id)

@router.put("/roles/{role_id}/memory")
@local_mutation
async def update_memory(role_id: str, update: MemoryUpdate, x_base_version: Optional[str] = Header(default=None)):
    """更新角色记忆"""
    memory = load_memory(role_id)
    from services import sync_service
    sync_service.check_version("memory", role_id, x_base_version, ROLES_DIR.parent, memory)
    
    if update.core_memory is not None:
        memory["core_memory"] = update.core_memory
    if update.short_term is not None:
        memory["short_term"] = update.short_term
    
    save_memory(role_id, memory)
    return memory

@router.post("/roles/{role_id}/memory/append")
@local_mutation
async def append_memory(role_id: str, content: str):
    """追加短期记忆"""
    memory = load_memory(role_id)
    memory["short_term"].append({
        "content": content,
        "timestamp": datetime.now().isoformat()
    })
    # 保留最近 50 条
    memory["short_term"] = memory["short_term"][-50:]
    save_memory(role_id, memory)
    return memory

# ========== 素材管理 ==========

import uuid
import shutil
from fastapi import UploadFile, File
from fastapi.responses import FileResponse

ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}

def get_assets_dir(role_id: str) -> Path:
    """获取角色素材目录"""
    assets_dir = get_role_dir(role_id) / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    return assets_dir

def get_asset_metadata_file(role_id: str) -> Path:
    """获取素材元数据文件"""
    return get_role_dir(role_id) / "assets_meta.json"

def load_assets_metadata(role_id: str) -> List[Dict]:
    """加载素材元数据"""
    meta_file = get_asset_metadata_file(role_id)
    if meta_file.exists():
        with open(meta_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return []

def save_assets_metadata(role_id: str, metadata: List[Dict]):
    """保存素材元数据"""
    meta_file = get_asset_metadata_file(role_id)
    from services.sync_service import write_json
    write_json(meta_file, metadata)

@router.get("/roles/{role_id}/assets")
async def list_assets(role_id: str):
    """获取角色素材列表"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    metadata = load_assets_metadata(role_id)
    return {"role_id": role_id, "assets": metadata}

@router.post("/roles/{role_id}/assets")
async def upload_asset(
    role_id: str,
    file: UploadFile = File(...),
    asset_type: str = "sticker"  # sticker / image
):
    """上传素材"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    if asset_type not in ('sticker', 'image'):
        raise HTTPException(422, '素材用途无效')
    from services.upload_service import image
    content, extension = await image(file)
    
    # 检查文件类型
    ext = Path(file.filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"不支持的文件类型: {ext}")
    
    # 生成唯一文件名
    asset_id = str(uuid.uuid4())
    filename = f"{asset_id}{ext}"
    
    # 保存文件
    assets_dir = get_assets_dir(role_id)
    file_path = assets_dir / filename
    
    with open(file_path, "xb") as f:
        f.write(content)
    
    # 更新元数据
    metadata = load_assets_metadata(role_id)
    asset_info = {
        "id": asset_id,
        "filename": filename,
        "original_name": file.filename,
        "type": asset_type,
        "size": len(content),
        "created_at": datetime.now().isoformat()
    }
    metadata.append(asset_info)
    save_assets_metadata(role_id, metadata)
    
    return asset_info

@router.get("/roles/{role_id}/assets/{asset_id}")
async def get_asset(role_id: str, asset_id: str, request: Request):
    """获取素材文件"""
    metadata = load_assets_metadata(role_id)
    asset = next((a for a in metadata if a["id"] == asset_id), None)
    
    if not asset:
        raise HTTPException(status_code=404, detail="素材不存在")
    
    file_path = get_assets_dir(role_id) / asset["filename"]
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    
    return resource_response(file_path, request)

@router.delete("/roles/{role_id}/assets/{asset_id}")
async def delete_asset(role_id: str, asset_id: str):
    """删除素材"""
    metadata = load_assets_metadata(role_id)
    asset = next((a for a in metadata if a["id"] == asset_id), None)
    
    if not asset:
        raise HTTPException(status_code=404, detail="素材不存在")
    
    # 删除文件
    file_path = get_assets_dir(role_id) / asset["filename"]
    if file_path.exists():
        file_path.unlink()
    
    # 更新元数据
    metadata = [a for a in metadata if a["id"] != asset_id]
    save_assets_metadata(role_id, metadata)
    
    return {"success": True}

@router.get("/roles/{role_id}/assets/type/{asset_type}")
async def list_assets_by_type(role_id: str, asset_type: str):
    """按类型获取素材列表"""
    metadata = load_assets_metadata(role_id)
    filtered = [a for a in metadata if a.get("type") == asset_type]
    return {"role_id": role_id, "type": asset_type, "assets": filtered}

# ========== 表情包接口 ==========

@router.get("/emojis/{role_id}/{emotion}/{filename}")
async def get_emoji(role_id: str, emotion: str, filename: str, request: Request):
    """获取角色表情包文件"""
    from fastapi.responses import FileResponse
    from fastapi import HTTPException
    
    emoji_path = ROLES_DIR / role_id / "emojis" / emotion / filename
    if emoji_path.exists() and emoji_path.is_file():
        return resource_response(emoji_path, request)
    raise HTTPException(status_code=404, detail="Emoji not found")

@router.get("/roles/{role_id}/emojis/{emotion}/random")
async def get_random_emoji(role_id: str, emotion: str):
    """从后端表情包文件夹中随机选择一个表情包"""
    import random
    
    emoji_dir = ROLES_DIR / role_id / "emojis" / emotion
    if not emoji_dir.exists():
        return {"found": False, "emotion": emotion}
    
    # 扫描支持的图片格式
    supported_ext = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
    files = [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in supported_ext]
    
    if not files:
        return {"found": False, "emotion": emotion}
    
    chosen = random.choice(files)
    # 返回可访问的 URL 路径
    return {
        "found": True,
        "emotion": emotion,
        "filename": chosen.name,
        "url": f"/api/emojis/{role_id}/{emotion}/{chosen.name}?v={version(chosen)}"
    }

# ========== 角色头像上传 ==========

@router.post("/roles/{role_id}/avatar")
async def upload_role_avatar(role_id: str):
    """上传角色头像"""
    from fastapi import UploadFile, File
    from fastapi.responses import JSONResponse
    import shutil
    
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    # 这个端点需要通过表单上传文件
    return JSONResponse({"error": "Use multipart form upload"}, status_code=400)

@router.post("/roles/{role_id}/avatar/upload")
async def upload_role_avatar_file(role_id: str, file: UploadFile = File(...)):
    """上传角色头像文件"""
    from fastapi.responses import FileResponse
    import shutil
    import uuid
    
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    from services.upload_service import image
    content, ext = await image(file)
    role = load_role(role_id)
    if not role:
        raise HTTPException(404, '角色已删除，原数据未修改')
    
    role_dir = get_role_dir(role_id)
    
    # 获取文件扩展名
    avatar_filename = f"avatar_{uuid.uuid4().hex}.{ext}"
    avatar_path = role_dir / "assets" / avatar_filename
    
    # 保存文件
    avatar_path.parent.mkdir(parents=True, exist_ok=True)
    with open(avatar_path, "xb") as f:
        f.write(content)
    
    # 更新角色 avatar_url
    avatar_url = f"/api/roles/{role_id}/avatar/file"
    avatar_url += f"?v={version(avatar_path)}"
    role["avatar_file"] = avatar_filename
    role["avatar_url"] = avatar_url
    save_role(role_id, role)
    from services.scheduler_service import get_scheduler, schedule_proactive_for_role
    scheduler = get_scheduler()
    if scheduler.get_job("proactive_" + role_id):
        scheduler.remove_job("proactive_" + role_id)
    schedule_proactive_for_role(role_id)
    
    return {"success": True, "avatar_url": avatar_url}

@router.get("/roles/{role_id}/avatar/file")
async def get_role_avatar_file(role_id: str, request: Request):
    """获取角色头像文件"""
    from fastapi.responses import FileResponse
    
    role_dir = get_role_dir(role_id)
    assets_dir = role_dir / "assets"
    
    role = load_role(role_id)
    if role and role.get("avatar_file"):
        avatar_path = assets_dir / Path(role["avatar_file"]).name
        if avatar_path.is_file():
            return resource_response(avatar_path, request)
    # 查找头像文件
    for ext in ["jpg", "jpeg", "png", "gif", "webp"]:
        avatar_path = assets_dir / f"avatar.{ext}"
        if avatar_path.exists():
            return resource_response(avatar_path, request)
    
    raise HTTPException(status_code=404, detail="Avatar not found")

# ========== 聊天记录同步接口 ==========

class ChatMessage(BaseModel):
    """聊天消息"""
    id: str
    content: str
    sender_id: str
    timestamp: str
    type: Optional[str] = "text"
    audio_url: Optional[str] = Field(default=None, max_length=256)
    duration_ms: Optional[int] = Field(default=None, ge=1, le=180000)
    quote_id: Optional[str] = None
    quote_content: Optional[str] = None

class ChatMessagesSync(BaseModel):
    """消息同步请求"""
    messages: List[ChatMessage]

@router.get("/roles/{role_id}/chats/messages")
async def get_chat_messages(role_id: str, limit: int = 50, offset: int = 0,
                            before: Optional[str] = None, after: Optional[int] = None):
    """Newest page or keyset history; incremental synchronization uses after."""
    if after is not None and after < 0:
        raise HTTPException(status_code=422, detail="Invalid synchronization cursor")
    try:
        result = await run_in_threadpool(history_service.page,
            get_role_dir(role_id) / "chats", limit, before, after, offset)
    except ValueError as error:
        logger.warning("", extra={"event": "history_page_rejected", "error_type": type(error).__name__})
        raise HTTPException(status_code=422, detail="Invalid history or page parameters; original retained")
    logger.info("", extra={"event": "history_page", "role_ref": reference(role_id),
                         "count": len(result["messages"]), "limit": limit})
    return {"role_id": role_id, **result}


@router.post("/roles/{role_id}/chats/messages")
async def save_chat_message(role_id: str, message: ChatMessage):
    await run_in_threadpool(history_service.append, get_role_dir(role_id) / "chats",
                            [message.model_dump()])
    return {"success": True, "message_id": message.id}


@router.post("/roles/{role_id}/chats/sync")
async def sync_chat_messages(role_id: str, sync: ChatMessagesSync):
    return await run_in_threadpool(history_service.append, get_role_dir(role_id) / "chats",
                                   [message.model_dump() for message in sync.messages])


@router.delete("/roles/{role_id}/chats/messages")
async def clear_chat_messages(role_id: str):
    return await run_in_threadpool(history_service.remove, get_role_dir(role_id) / "chats")


@router.delete("/roles/{role_id}/chats/messages/{message_id}")
async def delete_chat_message(role_id: str, message_id: str):
    return await run_in_threadpool(history_service.remove, get_role_dir(role_id) / "chats", message_id)
