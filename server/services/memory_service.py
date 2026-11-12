"""
记忆服务
管理角色的短期记忆和核心记忆
"""
import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any
from services.logging_service import get_logger, reference
from services.sync_service import local_commit

logger = get_logger("memory")

from services.paths_service import DATA_DIR
ROLES_DIR = DATA_DIR / "roles"

def get_memory_file(role_id: str) -> Path:
    from services.sync_service import identity
    identity(role_id)
    role_dir = ROLES_DIR / role_id
    role_dir.mkdir(parents=True, exist_ok=True)
    return role_dir / "memory.json"

def load_memory(role_id: str) -> Dict:
    """加载角色记忆"""
    memory_file = get_memory_file(role_id)
    if memory_file.exists():
        with open(memory_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {
        "core_memory": "",
        "short_term": [],
        "last_summarized_at": None,
        "message_count_since_summary": 0
    }

def save_memory(role_id: str, memory: Dict):
    """保存角色记忆"""
    memory_file = get_memory_file(role_id)
    memory["updated_at"] = datetime.now().isoformat()
    from services.sync_service import write_json
    write_json(memory_file, memory)
    logger.info("", extra={"event": "memory_saved", "role_ref": reference(role_id)})

@local_commit
def append_short_term(role_id: str, role: str, content: str):
    """
    追加短期记忆
    
    Args:
        role_id: 角色 ID
        role: 消息角色 (user/assistant)
        content: 消息内容
    """
    memory = load_memory(role_id)
    
    memory["short_term"].append({
        "id": uuid.uuid4().hex,
        "role": role,
        "content": content,
        "timestamp": datetime.now().isoformat()
    })
    
    # 保留最近 50 条
    memory["short_term"] = memory["short_term"][-50:]
    memory["message_count_since_summary"] = memory.get("message_count_since_summary", 0) + 1
    
    save_memory(role_id, memory)

def get_context_messages(role_id: str, limit: int = 20) -> List[Dict]:
    """
    获取对话上下文消息
    
    Returns:
        [{"role": "user/assistant", "content": "..."}]
    """
    from services import hybrid_memory_service as hybrid
    hybrid.ensure_index()
    rows = [e for e in hybrid.entries_from_index() if e.get("category") == "short_term"
            and hybrid.allowed(e, role_id, role_id)]
    rows.sort(key=lambda e: (e.get('message_time') or e['created_at'], e.get('message_order', 0), e['id']))
    return [{"role": "assistant" if e["source"].endswith(":assistant") else "user", "content": e["content"]}
            for e in (rows[-limit:] if limit > 0 else [])]

def get_core_memory(role_id: str) -> str:
    """获取核心记忆"""
    from services import hybrid_memory_service as hybrid
    hybrid.ensure_index()
    return "\n".join(e["content"] for e in hybrid.entries_from_index()
                     if e.get("category") == "core" and hybrid.allowed(e, role_id, role_id))

@local_commit
def update_core_memory(role_id: str, core_memory: str):
    """更新核心记忆（由 AI 总结生成）"""
    memory = load_memory(role_id)
    memory["core_memory"] = core_memory
    memory["last_summarized_at"] = datetime.now().isoformat()
    memory["message_count_since_summary"] = 0
    save_memory(role_id, memory)

def should_summarize(role_id: str) -> bool:
    """
    判断是否需要总结核心记忆
    
    条件：
    - 距离上次总结超过 30 条消息
    - 或从未总结过且超过 20 条消息
    """
    memory = load_memory(role_id)
    count = memory.get("message_count_since_summary", 0)
    last_summarized = memory.get("last_summarized_at")
    
    if last_summarized is None:
        return count >= 20
    return count >= 30

async def trigger_memory_summary(role_id: str, role_data: Dict, force=False) -> Optional[str]:
    """
    触发记忆总结（内部调用，不暴露给前端）
    
    Returns:
        新的核心记忆内容，或 None（如果不需要总结）
    """
    memory = load_memory(role_id)
    interval = max(1, min(1000, role_data.get("summary_every_n_rounds", 20))) * 2
    if not force and memory.get("message_count_since_summary", 0) < interval:
        return None
    
    # 导入 AI 服务
    from services.ai_service import call_ai
    
    memory = load_memory(role_id)
    summarized_count = memory.get('message_count_since_summary', 0)
    short_term = get_context_messages(role_id, 30)
    current_core = get_core_memory(role_id)
    
    # 构建总结提示
    conversation = "\n".join([
        f"{'用户' if m['role'] == 'user' else '你'}：{m['content']}"
        for m in short_term[-30:]
    ])
    
    prompt = f"""基于以下对话，总结用户的关键信息（如喜好、习惯、重要事件）。

当前已有的核心记忆：
{current_core if current_core else '（暂无）'}

最近对话：
{conversation}

请输出更新后的核心记忆（100字以内），格式为要点列表。只输出记忆内容，不要解释。"""

    from services.ai_service import load_config
    messages = [{"role": "system", "content": load_config().get("memory_prompt", "")},
                {"role": "user", "content": prompt}]
    if force:
        result = await call_ai(messages, temperature=0.3, role_id=role_id)
    else:
        from services import behavior_service as autonomy
        if autonomy.gate(role_id, "memory") != "ready":
            return None
        with autonomy.optional(role_id, "memory", "summary:" + role_id):
            result = await call_ai(messages, temperature=0.3, role_id=role_id)
    
    if result["success"] and result["content"]:
        new_core = result["content"].strip()
        from services.hybrid_memory_service import propose
        propose(role_id, new_core, "单聊自动总结，需用户确认；来源为最近30条对话")
        _finish_summary(role_id, summarized_count)
        return new_core
    
    return None

@local_commit
def _finish_summary(role_id: str, summarized_count: int):
    memory = load_memory(role_id)
    memory['last_summarized_at'] = datetime.now().isoformat()
    memory['message_count_since_summary'] = max(0, memory.get('message_count_since_summary', 0) - summarized_count)
    save_memory(role_id, memory)


@local_commit
def clear_short_term(role_id: str):
    """清空短期记忆"""
    memory = load_memory(role_id)
    memory["short_term"] = []
    save_memory(role_id, memory)

def get_memory_context_string(role_id: str, query: str = "", chat_id: str = None) -> str:
    """
    获取记忆上下文字符串（用于 AI 提示）
    """
    from services.hybrid_memory_service import context
    return context(role_id, query, chat_id)
