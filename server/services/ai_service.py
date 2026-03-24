"""
AI 服务
统一处理所有 AI API 调用
"""
import json
import httpx
from pathlib import Path
from typing import Optional, List, Dict, Any

CONFIG_DIR = Path(__file__).parent.parent / "config"

def load_config() -> Dict:
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

async def call_ai(
    messages: List[Dict[str, str]],
    model: Optional[str] = None,
    temperature: float = 0.7,
    top_p: float = 1.0,
    frequency_penalty: float = 0.0,
    presence_penalty: float = 0.0,
    max_tokens: int = 1000
) -> Dict[str, Any]:
    """
    统一 AI API 调用
    
    Args:
        messages: 消息列表 [{"role": "system/user/assistant", "content": "..."}]
        model: 模型名称，默认从配置读取
        temperature: 温度参数
        top_p: Top P 参数
        frequency_penalty: 频率惩罚
        presence_penalty: 存在惩罚
        max_tokens: 最大 token 数
    
    Returns:
        {"success": bool, "content": str, "error": str}
    """
    config = load_config()
    api_url = config.get("ai_api_url", "")
    api_key = config.get("ai_api_key", "")
    default_model = config.get("ai_model", "gpt-3.5-turbo")
    
    if not api_url or not api_key:
        return {"success": False, "content": None, "error": "AI API 未配置"}
    
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                api_url,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": model or default_model,
                    "messages": messages,
                    "temperature": temperature,
                    "top_p": top_p,
                    "frequency_penalty": frequency_penalty,
                    "presence_penalty": presence_penalty,
                    "max_tokens": max_tokens
                }
            )
            response.raise_for_status()
            data = response.json()
            
            content = data["choices"][0]["message"]["content"]
            return {"success": True, "content": content, "error": None}
            
    except httpx.HTTPError as e:
        return {"success": False, "content": None, "error": f"HTTP Error: {str(e)}"}
    except Exception as e:
        return {"success": False, "content": None, "error": str(e)}

async def generate_with_role(
    role_data: Dict,
    user_message: str,
    history: Optional[List[Dict]] = None,
    extra_context: Optional[str] = None
) -> Dict[str, Any]:
    """
    以角色身份生成回复
    
    Args:
        role_data: 角色数据（含 persona, system_prompt, temperature 等）
        user_message: 用户消息
        history: 历史消息
        extra_context: 额外上下文（如记忆）
    """
    messages = []
    
    # 系统提示词
    system_prompt = role_data.get("system_prompt", "")
    persona = role_data.get("persona", "")
    
    if persona or system_prompt:
        system_content = ""
        if persona:
            system_content += f"你的人设：{persona}\n\n"
        if system_prompt:
            system_content += system_prompt
        if extra_context:
            system_content += f"\n\n额外上下文：{extra_context}"
        
        # 注入当前日期时间
        from datetime import datetime
        weekdays = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
        now = datetime.now()
        weekday = weekdays[now.weekday()]
        system_content += f"\n\n[当前时间信息]\n当前日期：{now.strftime('%Y年%m月%d日')} {weekday}\n当前时间：{now.strftime('%H:%M')}"
        
        messages.append({"role": "system", "content": system_content})
    
    # 读取角色 AI 参数
    temperature = role_data.get("temperature", 0.7)
    top_p = role_data.get("top_p", 1.0)
    frequency_penalty = role_data.get("frequency_penalty", 0.0)
    presence_penalty = role_data.get("presence_penalty", 0.0)
    max_context_rounds = role_data.get("max_context_rounds", 10)
    
    # 历史消息（按角色配置的轮数限制）
    if history:
        max_messages = max_context_rounds * 2
        for msg in history[-max_messages:]:
            messages.append({
                "role": msg.get("role", "user"),
                "content": msg.get("content", "")
            })
    
    # 当前消息
    messages.append({"role": "user", "content": user_message})
    
    return await call_ai(
        messages,
        temperature=temperature,
        top_p=top_p,
        frequency_penalty=frequency_penalty,
        presence_penalty=presence_penalty,
    )

async def generate_proactive_message(
    role_data: Dict,
    trigger_prompt: str,
    memory_context: Optional[str] = None
) -> Dict[str, Any]:
    """
    生成主动消息（无需用户输入）
    """
    messages = []
    
    persona = role_data.get("persona", "")
    system_prompt = role_data.get("system_prompt", "")
    
    system_content = ""
    if persona:
        system_content += f"你的人设：{persona}\n\n"
    if system_prompt:
        system_content += system_prompt
    if memory_context:
        system_content += f"\n\n你对用户的记忆：{memory_context}"
    
    system_content += "\n\n你现在想主动给用户发一条消息，要求自然、符合人设，不要提及'主动''系统'等词。"
    
    messages.append({"role": "system", "content": system_content})
    messages.append({"role": "user", "content": trigger_prompt or "请发起一个自然的话题"})
    
    return await call_ai(messages, temperature=0.8)

async def generate_moment_post(
    role_data: Dict,
    mood: Optional[str] = None
) -> Dict[str, Any]:
    """
    生成朋友圈内容
    """
    persona = role_data.get("persona", "")
    name = role_data.get("name", "AI")
    
    prompt = f"""你是{name}，你的人设：{persona}

现在你想发一条朋友圈动态。要求：
- 内容简短自然（20-100字）
- 符合你的性格和人设
- 可以是生活感悟、心情分享、日常记录
- 不要提及"AI""系统""人设"等词
{f'- 当前心情偏向：{mood}' if mood else ''}

直接输出朋友圈内容，不要任何解释。"""

    messages = [{"role": "user", "content": prompt}]
    return await call_ai(messages, temperature=0.9)

async def generate_moment_comment(
    role_data: Dict,
    post_content: str,
    post_author: str,
    reply_to: Optional[str] = None
) -> Dict[str, Any]:
    """
    生成朋友圈评论
    """
    persona = role_data.get("persona", "")
    name = role_data.get("name", "AI")
    
    prompt = f"""你是{name}，你的人设：{persona}

{post_author}发了一条朋友圈：「{post_content}」

{'你要回复'+reply_to+'的评论' if reply_to else '你想评论这条朋友圈'}。要求：
- 简短自然（5-30字）
- 像朋友间的互动
- 可以用表情或语气词
- 不要太正式

直接输出评论内容。"""

    messages = [{"role": "user", "content": prompt}]
    return await call_ai(messages, temperature=0.8)
