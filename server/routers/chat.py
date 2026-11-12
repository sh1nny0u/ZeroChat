"""
聊天路由
处理 AI 对话请求
"""
import json
from datetime import datetime
from pathlib import Path
from typing import Optional, List
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException
import httpx
from services.logging_service import get_logger

logger = get_logger("chat")

router = APIRouter()

# 数据目录
from services.paths_service import DATA_DIR
CHATS_DIR = DATA_DIR / "chats"
from services.paths_service import CONFIG_DIR

class ChatMessage(BaseModel):
    role: str  # user / assistant / system
    content: str

class ChatRequest(BaseModel):
    request_id: str
    chat_id: str
    role_id: str
    message: str
    system_prompt: Optional[str] = None
    history: Optional[List[ChatMessage]] = None

class ChatResponse(BaseModel):
    success: bool
    content: Optional[str] = None
    error: Optional[str] = None

def load_config():
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def save_chat_message(chat_id: str, role: str, content: str):
    """保存聊天消息"""
    chat_file = CHATS_DIR / f"{chat_id}.json"
    messages = []
    if chat_file.exists():
        with open(chat_file, "r", encoding="utf-8") as f:
            messages = json.load(f)
    
    messages.append({
        "id": f"{datetime.now().timestamp()}",
        "role": role,
        "content": content,
        "timestamp": datetime.now().isoformat()
    })
    
    with open(chat_file, "w", encoding="utf-8") as f:
        json.dump(messages, f, indent=2, ensure_ascii=False)

def get_chat_history(chat_id: str, limit: int = 20) -> List[dict]:
    """获取聊天历史"""
    chat_file = CHATS_DIR / f"{chat_id}.json"
    if not chat_file.exists():
        return []
    with open(chat_file, "r", encoding="utf-8") as f:
        messages = json.load(f)
    return messages[-limit:]

@router.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """AI 对话接口"""
    from routers.ai_behavior import AIEvent
    from services.event_service import execute
    result = await execute(AIEvent(request_id=request.request_id, role_id=request.role_id,
        event_type="chat", content=request.message, context={"chat_id": request.chat_id}))
    return ChatResponse(success=result.success, content=result.content, error=result.error)

@router.get("/chats/{chat_id}/history")
async def get_history(chat_id: str, limit: int = 50):
    """获取聊天历史"""
    history = get_chat_history(chat_id, limit)
    return {"chat_id": chat_id, "messages": history}

@router.delete("/chats/{chat_id}")
async def clear_chat(chat_id: str):
    """清空聊天记录"""
    chat_file = CHATS_DIR / f"{chat_id}.json"
    if chat_file.exists():
        chat_file.unlink()
    return {"success": True}


@router.get("/search")
async def search(q: str):
    """按需联网搜索（GET /api/search?q=关键词）"""
    from services.search_service import should_search, web_search, format_search_results
    
    triggered = should_search(q)
    results = []
    formatted = ""
    
    if triggered:
        results = await web_search(q, max_results=3)
        formatted = format_search_results(results)
    
    return {
        "query": q,
        "triggered": triggered,
        "result_count": len(results),
        "results": results,
        "formatted": formatted,
    }
