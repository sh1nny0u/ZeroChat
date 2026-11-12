"""
AI 行为统一入口
处理所有 AI 事件：聊天、主动消息、定时任务、朋友圈
"""
import json
import random
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
from fastapi import APIRouter, HTTPException
from services.logging_service import get_logger

logger = get_logger("chat")

router = APIRouter()

from services.paths_service import DATA_DIR
ROLES_DIR = DATA_DIR / "roles"

# ========== 数据模型 ==========

class AIEventType(str, Enum):
    CHAT = "chat"              # 用户聊天消息
    TASK = "task"              # 定时任务触发
    PROACTIVE = "proactive"    # 主动消息
    MOMENT_POST = "moment"     # 发朋友圈
    MEMORY = "memory"
    MOMENT_COMMENT = "comment" # 朋友圈评论

class AIEvent(BaseModel):
    request_id: str = Field(min_length=8, max_length=180)
    role_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    event_type: AIEventType
    content: Optional[str] = ""
    quote_id: Optional[str] = Field(default=None, max_length=200)
    quote_content: Optional[str] = Field(default=None, max_length=1000)
    context: Optional[Dict[str, Any]] = {}

class AIResponse(BaseModel):
    success: bool
    action: Optional[str] = None      # reply / ignore / post / comment
    content: Optional[str] = None
    error: Optional[str] = None
    metadata: Optional[Dict] = {}

# ========== 辅助函数 ==========

def load_role(role_id: str) -> Optional[Dict]:
    if not role_id.replace("_", "").replace("-", "").isalnum() or len(role_id) > 128:
        raise HTTPException(422, "无效角色编号")
    profile_file = ROLES_DIR / role_id / "profile.json"
    if profile_file.exists():
        with open(profile_file, "r", encoding="utf-8") as f:
            data = json.load(f)
            return None if data.get("deleted") else data
    return None

def detect_emotion_and_get_emoji(role_id: str, text: str) -> Optional[str]:
    """
    检测文本情绪并返回对应表情包路径
    
    表情包目录结构: roles/{role_id}/emojis/{emotion}/
    支持的情绪: happy, sad, angry, surprised, love, confused, excited, tired
    """
    # 简单情绪关键词匹配
    emotion_keywords = {
        "happy": ["开心", "高兴", "哈哈", "😊", "😄", "太好了", "棒", "喜欢", "快乐", "nice", "great"],
        "sad": ["难过", "伤心", "哭", "😢", "😭", "抱歉", "遗憾", "可惜", "唉"],
        "angry": ["生气", "愤怒", "😠", "😡", "讨厌", "烦", "气死"],
        "surprised": ["惊讶", "天哪", "😲", "😮", "竟然", "居然", "什么", "wow", "不敢相信"],
        "love": ["爱你", "喜欢你", "❤️", "💕", "😍", "亲爱", "宝贝", "想你"],
        "confused": ["困惑", "不懂", "🤔", "奇怪", "为什么", "怎么回事", "不明白"],
        "excited": ["兴奋", "激动", "🎉", "太棒了", "期待", "迫不及待", "耶"],
        "tired": ["累", "困", "😴", "休息", "睡觉", "疲惫"]
    }
    
    text_lower = text.lower()
    detected_emotion = None
    
    for emotion, keywords in emotion_keywords.items():
        for keyword in keywords:
            if keyword.lower() in text_lower:
                detected_emotion = emotion
                break
        if detected_emotion:
            break
    
    if not detected_emotion:
        return None
    
    # 检查对应表情包目录
    emoji_dir = ROLES_DIR / role_id / "emojis" / detected_emotion
    if not emoji_dir.exists():
        return None
    
    # 获取目录中的图片文件
    image_extensions = (".png", ".jpg", ".jpeg", ".gif", ".webp")
    emoji_files = [f for f in emoji_dir.iterdir() if f.suffix.lower() in image_extensions]
    
    if not emoji_files:
        return None
    
    # 随机选择一个
    selected = random.choice(emoji_files)
    return f"/api/emojis/{role_id}/{detected_emotion}/{selected.name}"

# ========== 统一入口 ==========

@router.post("/ai/event", response_model=AIResponse)
async def handle_ai_event(event: AIEvent):
    from services.event_service import execute
    return await execute(event)


async def process_ai_event(event: AIEvent):
    """
    AI 行为统一入口
    
    根据事件类型分发处理
    """
    role = load_role(event.role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    from services.behavior_service import context as behavior_context
    role = {**role, "_behavior_context": behavior_context(event.role_id,
        (event.context or {}).get("chat_id"), event.event_type.value)}
    
    # 根据事件类型分发
    if event.event_type == AIEventType.MEMORY:
        from services.memory_service import trigger_memory_summary
        result = await trigger_memory_summary(event.role_id, role, force=True)
        return AIResponse(success=result is not None, action="memory", content=result,
                          error=None if result is not None else "记忆整理失败，请检查供应商设置")
    if event.event_type == AIEventType.CHAT:
        return await handle_chat(role, event)
    elif event.event_type == AIEventType.PROACTIVE:
        return await handle_proactive(role, event)
    elif event.event_type == AIEventType.TASK:
        return await handle_task(role, event)
    elif event.event_type == AIEventType.MOMENT_POST:
        return await handle_moment_post(role, event)
    elif event.event_type == AIEventType.MOMENT_COMMENT:
        return await handle_moment_comment(role, event)
    else:
        return AIResponse(success=False, error="未知事件类型")

# ========== 聊天处理 ==========

async def handle_chat(role: Dict, event: AIEvent) -> AIResponse:
    """处理用户聊天消息"""
    from services.ai_service import generate_with_role
    from services.memory_service import (
        get_context_messages, get_memory_context_string,
        append_short_term, trigger_memory_summary
    )
    
    role_id = event.role_id
    user_message = event.content or ""
    if event.quote_content:
        user_message = "引用：" + event.quote_content + "\n" + user_message
    
    # 获取上下文
    history = get_context_messages(role_id, limit=role.get("max_context_rounds", 10) * 2)
    memory_context = get_memory_context_string(role_id, user_message)
    from services.ai_service import load_config
    from services.intent_service import apply_intent
    # 联网搜索（如果角色开启了搜索功能）
    search_context = ""
    allow_search = role.get("allow_web_search", True)
    if allow_search:
        from services.search_service import should_search, web_search, format_search_results
        if should_search(user_message):
            search_results = await web_search(user_message, max_results=5)
            search_context = format_search_results(search_results)
    
    # 合并额外上下文
    extra_parts = []
    from routers.moments import load_moments
    if random.random() < 0.25:
        posts = [p for p in load_moments()[:10] if p.get("author_id") == "me"]
        if posts:
            extra_parts.append("用户最近朋友圈（仅自然相关时提及）：" + posts[0]["content"][:1000])
    if memory_context:
        extra_parts.append(memory_context)
    if search_context:
        extra_parts.append(search_context)
    
    # 外挂 JSON 记录
    attached_json = role.get("attached_json_content", "")
    if attached_json:
        extra_parts.append(f"[外挂记录]\n{attached_json}")
    
    extra_context = "\n\n".join(extra_parts) if extra_parts else None
    
    # 生成回复
    result = await generate_with_role(
        role_data=role,
        user_message=user_message,
        history=history,
        extra_context=extra_context
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    await apply_intent(event, role)
    
    ai_reply = result["content"]
    
    # 更新记忆
    append_short_term(role_id, "user", user_message)
    from services.tts_service import prepare
    append_short_term(role_id, "assistant", prepare(ai_reply)[0])
    
    
    # 检测情绪并获取表情包
    emoji_url = detect_emotion_and_get_emoji(role_id, ai_reply)
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_reply,
        metadata={
            "role_name": role.get("name"),
            "emoji_url": emoji_url  # 如果有匹配的表情包，返回URL
        }
    )

# ========== 主动消息处理 ==========

async def handle_proactive(role: Dict, event: AIEvent) -> AIResponse:
    """处理主动消息触发"""
    from services.ai_service import generate_proactive_message
    from services.memory_service import get_memory_context_string, append_short_term
    
    role_id = event.role_id
    proactive_config = role.get("proactive_config", {})
    trigger_prompt = proactive_config.get("trigger_prompt", "")
    
    memory_context = get_memory_context_string(role_id, trigger_prompt)
    
    result = await generate_proactive_message(
        role_data=role,
        trigger_prompt=trigger_prompt,
        memory_context=memory_context
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    ai_message = result["content"]
    if ai_message.strip() == "[保持安静]":
        return AIResponse(success=True, action="ignore", metadata={"reason": "ai_declined"})
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={"type": "proactive", "role_name": role.get("name")}
    )

# ========== 定时任务处理 ==========

async def handle_task(role: Dict, event: AIEvent) -> AIResponse:
    """处理定时任务触发"""
    from services.ai_service import generate_with_role
    from services.memory_service import get_memory_context_string, append_short_term
    
    role_id = event.role_id
    task_prompt = event.content or ""
    task_context = event.context or {}
    
    group_chat = task_context.get("chat_id", role_id) != role_id
    memory_context = get_memory_context_string(role_id, task_prompt, task_context.get("chat_id", role_id))
    
    result = await generate_with_role(
        role_data=role,
        user_message=task_prompt,
        extra_context=memory_context
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    ai_message = result["content"]
    if not group_chat:
        from services.tts_service import prepare
        append_short_term(role_id, "assistant", prepare(ai_message)[0])
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={"type": "task", "task_id": task_context.get("task_id")}
    )

# ========== 朋友圈发布 ==========

async def handle_moment_post(role: Dict, event: AIEvent) -> AIResponse:
    """AI 发布朋友圈"""
    from services.ai_service import generate_moment_post
    
    mood = event.context.get("mood") if event.context else None
    
    result = await generate_moment_post(role_data=role, mood=mood)
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    if result["content"].strip() == "[保持安静]":
        return AIResponse(success=True, action="ignore", metadata={"reason": "ai_declined"})
    return AIResponse(
        success=True,
        action="post",
        content=result["content"],
        metadata={"role_name": role.get("name")}
    )

# ========== 朋友圈评论 ==========

async def handle_moment_comment(role: Dict, event: AIEvent) -> AIResponse:
    """AI 评论朋友圈"""
    from services.ai_service import generate_moment_comment
    
    context = event.context or {}
    post_content = context.get("post_content", "")
    post_author = context.get("post_author", "用户")
    reply_to = context.get("reply_to")
    
    # 概率决定是否互动
    if random.random() > 0.5:
        return AIResponse(success=True, action="ignore", content=None)
    
    result = await generate_moment_comment(
        role_data=role,
        post_content=post_content,
        post_author=post_author,
        reply_to=reply_to
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])

    if result["content"].strip() == "[保持安静]":
        return AIResponse(success=True, action="ignore", metadata={"reason": "ai_declined"})
    
    return AIResponse(
        success=True,
        action="comment",
        content=result["content"],
        metadata={"role_name": role.get("name")}
    )

# ========== 状态查询 ==========

@router.get("/ai/status/{role_id}")
async def get_ai_status(role_id: str):
    """获取角色 AI 状态"""
    from services.memory_service import load_memory
    
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    memory = load_memory(role_id)
    proactive_config = role.get("proactive_config", {})
    
    return {
        "role_id": role_id,
        "role_name": role.get("name"),
        "proactive_enabled": proactive_config.get("enabled", False),
        "memory_summary_count": memory.get("message_count_since_summary", 0),
        "has_core_memory": bool(memory.get("core_memory")),
        "short_term_count": len(memory.get("short_term", []))
    }


# ========== 图片识别 ==========

class VisionRequest(BaseModel):
    request_id: str = Field(min_length=8, max_length=128)
    role_id: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9_-]{1,128}$")
    chat_id: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9_-]{1,128}$")
    image_base64: str = Field(max_length=12 * 1024 * 1024)
    mime_type: str = "image/jpeg"
    user_prompt: str = "请描述这张图片的内容"
    system_prompt: str = ""


@router.post("/chat/vision")
async def chat_with_vision(request: VisionRequest):
    from services.ai_service import call_ai
    from services import operation_service
    from services.settings_service import load_settings
    if not load_settings().get('vision_enabled', False):
        raise HTTPException(409, '图片识别未启用，请在 AI 接口设置启用并保存后手动重试')
    if request.mime_type not in ("image/jpeg", "image/png", "image/webp"):
        raise HTTPException(422, "不支持的图片格式")
    key = "vision:" + request.request_id
    if request.role_id:
        role = load_role(request.role_id)
        if not role:
            raise HTTPException(404, "角色不存在")
        request.system_prompt = role.get("system_prompt", "")
        if request.chat_id and request.chat_id != request.role_id:
            from routers.groups import load
            group = load(request.chat_id)
            if request.role_id not in group.member_ids:
                raise HTTPException(403, "角色不是群聊成员")
    from services.delivery_service import validate_image, store_image
    image_data = validate_image(request.image_base64)
    operation_service.claim(key, request.model_dump())
    image_url = store_image(request.request_id, image_data, request.mime_type) if request.role_id else None
    result = await call_ai([
        {"role": "system", "content": request.system_prompt},
        {"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:{request.mime_type};base64,{request.image_base64}"}},
            {"type": "text", "text": request.user_prompt}]}], max_tokens=1024, purpose="vision")
    if not result["success"]:
        operation_service.finish(key, operation_service.failure_state(result["error"]))
        raise HTTPException(502, result["error"])
    rows = []
    if request.role_id:
        from services.delivery_service import save_image, replies
        from services.event_service import message, conversation_dir
        from services import history_service
        image = message(request.request_id + "_user", "me", image_url)
        image["type"] = "image"
        rows = [image, *replies(request.request_id, request.role_id, result["content"])]
        history_service.append(conversation_dir(request.chat_id or request.role_id, request.role_id), rows)
    operation_service.finish(key)
    return {"reply": result["content"], "success": True, "messages": rows}


class CompletionRequest(BaseModel):
    request_id: str = Field(min_length=8, max_length=128)
    message: str = Field(max_length=100000)
    system_prompt: str = Field(default="", max_length=100000)


@router.post("/ai/completion")
async def completion(body: CompletionRequest):
    from services import ai_service, operation_service
    key = "completion:" + body.request_id
    operation_service.claim(key, body.model_dump())
    result = await ai_service.call_ai([{"role": "system", "content": body.system_prompt},
                                     {"role": "user", "content": body.message}])
    operation_service.finish(key, "completed" if result["success"] else operation_service.failure_state(result["error"]))
    return result


@router.get("/ai/operations/{kind}/{identity}")
async def operation_status(kind: str, identity: str, chat_id: str = "", role_id: str = ""):
    from services.operation_service import status, in_flight
    from services.event_service import conversation_dir
    from services import history_service
    if kind not in ("event", "vision", "completion", "group"):
        raise HTTPException(422, "无效操作类型")
    rows = []
    if chat_id and role_id:
        if not all(value.replace("_", "").replace("-", "").isalnum() for value in (chat_id, role_id)):
            raise HTTPException(422, "无效会话编号")
        directory = conversation_dir(chat_id, role_id)
        if kind == "group":
            from routers.groups import directory as group_directory
            directory = group_directory(chat_id) / "chats"
        with history_service.database(directory) as db:
            found = db.execute("SELECT payload FROM messages WHERE id=? OR substr(id,1,?)=? ORDER BY sort_time,id",
                               (identity + "_user", len(identity + "_assistant"), identity + "_assistant")).fetchall()
            if kind == "group":
                found = db.execute("SELECT payload FROM messages WHERE id=? OR substr(id,1,?)=? ORDER BY sort_time,id",
                                   (identity + "_user", len(identity + "_reply_"), identity + "_reply_")).fetchall()
            rows = [json.loads(r[0]) for r in found]
    key = kind + ":" + identity
    return {"state": status(key), "in_flight": in_flight(key), "messages": rows}
