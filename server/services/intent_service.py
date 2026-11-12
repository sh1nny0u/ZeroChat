"""Optional model classification and side effects execute once per chat event."""
import json
from datetime import datetime, timedelta
from services import settings_service
from services.logging_service import get_logger


async def apply_intent(event, role):
    settings = settings_service.load_settings()
    if not settings.get("intent_enabled", False):
        return
    from services.ai_service import call_ai
    result = await call_ai([
        {"role": "system", "content": '识别用户明确请求。仅返回 JSON：{"intent":"normal_chat|set_memory|clear_memory|set_reminder|set_quiet_time","extracted_content":"内容","duration_seconds":0,"start_hour":23,"end_hour":7}。没有明确操作请求时返回 normal_chat。'},
        {"role": "user", "content": event.content or ""}], temperature=0.1,
        max_tokens=200, purpose="intent")
    if not result["success"]:
        get_logger("chat").warning("", extra={"event": "intent_provider_failed"})
        return
    try:
        content = result["content"]
        data = json.loads(content[content.index("{"):content.rindex("}") + 1])
        intent = data.get("intent")
        from services import memory_service
        if intent == "set_memory" and isinstance(data.get("extracted_content"), str):
            current = memory_service.get_core_memory(event.role_id)
            memory_service.update_core_memory(event.role_id, current + "\n" + data["extracted_content"][:4000])
        elif intent == "clear_memory":
            memory_service.update_core_memory(event.role_id, "")
            memory_service.clear_short_term(event.role_id)
        elif intent == "set_reminder":
            seconds = int(data.get("duration_seconds", 0))
            if not 0 < seconds <= 366 * 86400:
                return
            from routers.tasks import create_task, TaskCreate
            await create_task(TaskCreate(id="intent-" + event.request_id, chat_id=event.role_id,
                role_id=event.role_id, message=str(data.get("extracted_content") or event.content)[:4000],
                trigger_time=(datetime.now() + timedelta(seconds=seconds)).isoformat()))
        elif intent == "set_quiet_time":
            start, end = int(data["start_hour"]), int(data["end_hour"])
            if 0 <= start <= 23 and 0 <= end <= 23:
                settings_service.save_settings({"quiet_enabled": True, "quiet_start": start, "quiet_end": end})
    except Exception:
        get_logger("chat").warning("", extra={"event": "intent_invalid_result"})
