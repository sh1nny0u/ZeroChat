"""
AI 服务
统一处理所有 AI API 调用
"""
import json
import httpx
from pathlib import Path
from typing import Optional, List, Dict, Any
from urllib.parse import urlsplit, urlunsplit

from services.logging_service import get_logger, reference

logger = get_logger("chat")
from services.paths_service import CONFIG_DIR

def load_config() -> Dict:
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def completion_endpoint(url):
    parts = urlsplit(url.strip())
    path = parts.path.rstrip("/")
    if not path.endswith("/chat/completions"):
        path += "/chat/completions" if path or parts.hostname == "api.deepseek.com" else "/v1/chat/completions"
    return urlunsplit((parts.scheme, parts.netloc, path, parts.query, ""))


def models_endpoint(url):
    parts = urlsplit(completion_endpoint(url))
    return urlunsplit((parts.scheme, parts.netloc,
                      parts.path.removesuffix("chat/completions") + "models", parts.query, ""))


def completion_payload(api_url, model, messages, temperature, top_p,
                       frequency_penalty, presence_penalty, max_tokens):
    payload = {"model": model, "messages": messages, "max_tokens": max_tokens,
               "temperature": temperature, "top_p": top_p,
               "frequency_penalty": frequency_penalty, "presence_penalty": presence_penalty}
    host = urlsplit(api_url).hostname
    if host in ("api.deepseek.com", "open.bigmodel.cn", "api.moonshot.cn", "api.moonshot.ai"):
        payload.pop("frequency_penalty")
        payload.pop("presence_penalty")
    if host == "api.deepseek.com":
        payload["top_p"] = max(0.01, min(1, top_p))
    if host == "open.bigmodel.cn":
        payload["temperature"] = round(max(0, min(1, temperature)), 2)
        payload["top_p"] = round(max(0.01, min(1, top_p)), 2)
        # Only documented dual-mode families; e.g. GLM-5.3 rejects disabled.
        name = model.lower()
        if (name.startswith(("glm-4.5", "glm-4.6", "glm-4.7")) and not name.startswith("glm-4.5v")) or name in (
                "glm-5", "glm-5-turbo", "glm-5v-turbo", "glm-5.1", "glm-5.2"):
            payload["thinking"] = {"type": "disabled"}
    if host in ("api.moonshot.cn", "api.moonshot.ai") and model.lower().startswith("kimi-"):
        # Kimi generations have model-specific fixed sampling rules. Use the
        # official defaults instead of forwarding incompatible role sliders.
        payload.pop("temperature")
        payload.pop("top_p")
        if model.lower().startswith(("kimi-k2.5", "kimi-k2.6")):
            payload["thinking"] = {"type": "disabled"}
    if host == "api.deepseek.com" and model.lower().startswith(("deepseek-flash", "deepseek-v4")):
        payload["thinking"] = {"type": "disabled"}
    return payload


async def call_ai(
    messages: List[Dict[str, str]],
    model: Optional[str] = None,
    temperature: float = 0.7,
    top_p: float = 1.0,
    frequency_penalty: float = 0.0,
    presence_penalty: float = 0.0,
    max_tokens: int = 1000,
    purpose: str = "chat",
    role_id: Optional[str] = None
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
    from services.settings_service import provider_config
    selected = provider_config(config, purpose)
    api_url, api_key, default_model = selected['api_url'], selected['api_key'], selected['model']
    
    if purpose == "chat" and role_id:
        from services.role_api_service import resolve
        selected = resolve(role_id, config)
        api_url, api_key, default_model = selected["api_url"], selected["api_key"], selected["model"]
    role_log = {"role_ref": reference(role_id)} if role_id else {}

    if not api_url or not api_key:
        logger.warning("", extra={"event": "provider_not_configured", "error_type": "ConfigurationError", **role_log})
        return {"success": False, "content": None, "error": "AI API 未配置"}

    from services.behavior_service import reserve_call
    if not reserve_call(messages, max_tokens):
        return {"success": False, "content": None, "error": "自主行为预算不足或当前时段已暂停，正常聊天仍可用"}
    
    try:
        # Non-streaming reasoning/compatible gateways may need more than a
        # minute before their first byte. Connect failures still fail promptly.
        async with httpx.AsyncClient(timeout=httpx.Timeout(180.0, connect=15.0, write=30.0, pool=15.0)) as client:
            response = await client.post(
                completion_endpoint(api_url),
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json"
                },
                json=completion_payload(api_url, model or default_model, messages,
                    temperature, top_p, frequency_penalty, presence_penalty, max_tokens)
            )
            response.raise_for_status()
            data = response.json()
            
            content = data["choices"][0]["message"]["content"]
            if not isinstance(content, str) or not content.strip():
                return {"success": False, "content": None,
                        "error": "供应商未返回正文，可能已达到模型思考或输出限制；请确认模型配置后手动重试"}
            usage = cache_usage(data.get("usage"))
            logger.info("", extra={"event": "provider_usage", **role_log, **usage})
            return {"success": True, "content": content, "error": None, "usage": usage}
            
    except httpx.TimeoutException:
        logger.warning("", extra={"event": "provider_timeout", **role_log})
        return {"success": False, "content": None, "error": "供应商响应超时，未收到回复。请点击重试查询结果；确认重新发送可能重复计费"}
    except httpx.HTTPStatusError as error:
        status = error.response.status_code
        logger.warning("", extra={"event": "provider_rejected", "status": status, **role_log})
        reason = "供应商密钥无效或权限不足" if status in (401, 403) else "供应商限流或余额不足" if status in (402, 429) else "供应商服务暂时不可用"
        return {"success": False, "content": None, "error": reason + ("，结果未确认，请先刷新记录" if status >= 500 else "，请检查后端配置后手动重试")}
    except httpx.HTTPError:
        logger.exception("", extra={"event": "provider_http_failed", **role_log})
        return {"success": False, "content": None, "error": "AI 服务连接失败，结果未确认，请先刷新记录"}
    except Exception:
        logger.exception("", extra={"event": "provider_response_failed", **role_log})
        return {"success": False, "content": None, "error": "AI 服务返回异常，结果未确认，请先刷新记录"}

def cache_usage(raw):
    raw = raw if isinstance(raw, dict) else {}
    result = {}
    for key in ("prompt_tokens", "completion_tokens", "total_tokens", "prompt_cache_miss_tokens"):
        if type(raw.get(key)) is int and raw[key] >= 0:
            result[key] = raw[key]
    details = raw.get("prompt_tokens_details")
    cached = details.get("cached_tokens") if isinstance(details, dict) else None
    if cached is None:
        cached = raw.get("prompt_cache_hit_tokens")
    if type(cached) is int and cached >= 0:
        result["cached_tokens"] = cached
    result["cache_state"] = "unreported" if "cached_tokens" not in result else "hit" if result["cached_tokens"] else "miss"
    return result


def stable_prefix(role_data):
    messages = []
    base = load_config().get("base_prompt", "")
    if base:
        messages.append({"role": "system", "content": base})
    content = ""
    if role_data.get("persona"):
        content += "你的人设：" + role_data["persona"] + "\n\n"
    content += role_data.get("system_prompt") or ""
    if content:
        messages.append({"role": "system", "content": content})
    return messages


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
    messages = stable_prefix(role_data)
    # Dynamic context comes after the stable prefix; history roles stay intact.
    from datetime import datetime
    now = datetime.now()
    if role_data.get("_behavior_context"):
        from services.behavior_service import clock
        now = clock()
    weekdays = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    dynamic = f"[当前时间信息]\n当前日期：{now:%Y年%m月%d日} {weekdays[now.weekday()]}\n当前时间：{now:%H:%M}"
    if role_data.get("_behavior_context"):
        dynamic += "\n\n" + role_data["_behavior_context"]
    if extra_context:
        dynamic += "\n\n额外上下文：" + extra_context
    from services.tts_service import prompt as voice_prompt
    dynamic += voice_prompt(role_data.get("id")) if role_data.get("id") else ""
    messages.append({"role": "system", "content": dynamic})

    # 读取角色 AI 参数
    temperature = role_data.get("temperature", 0.7)
    top_p = role_data.get("top_p", 1.0)
    frequency_penalty = role_data.get("frequency_penalty", 0.0)
    presence_penalty = role_data.get("presence_penalty", 0.0)
    max_context_rounds = role_data.get("max_context_rounds", 10)
    
    # 历史消息（按角色配置的轮数限制）
    if history:
        max_messages = max_context_rounds * 2
        for msg in (history[-max_messages:] if max_messages > 0 else []):
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
        role_id=role_data.get("id"),
    )

async def generate_proactive_message(
    role_data: Dict,
    trigger_prompt: str,
    memory_context: Optional[str] = None
) -> Dict[str, Any]:
    """
    生成主动消息（无需用户输入）
    """
    messages = stable_prefix(role_data)
    content = "你现在想主动给用户发一条消息，要求自然、符合人设，不要提及'主动''系统'等词。"
    if memory_context:
        content += "\n\n你对用户的记忆：" + memory_context
    content += "\n" + role_data.get("_behavior_context", "")
    from services.tts_service import prompt as voice_prompt
    content += voice_prompt(role_data.get("id")) if role_data.get("id") else ""
    content += "\n先判断现在是否值得联系；不适合时只输出[保持安静]，不要勉强找话题。"
    messages.extend([{"role": "system", "content": content},
                     {"role": "user", "content": trigger_prompt or "请发起一个自然的话题"}])
    return await call_ai(messages, temperature=0.8, role_id=role_data.get("id"))

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

    prompt += "\n" + role_data.get("_behavior_context", "") + "\n没有合适经历可分享时只输出[保持安静]。"
    messages = [*stable_prefix(role_data), {"role": "user", "content": prompt}]
    return await call_ai(messages, temperature=0.9, role_id=role_data.get("id"))

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

    prompt += "\n" + role_data.get("_behavior_context", "") + "\n不适合互动时只输出[保持安静]。"
    messages = [*stable_prefix(role_data), {"role": "user", "content": prompt}]
    return await call_ai(messages, temperature=0.8, role_id=role_data.get("id"))
