"""All AI event execution and delivery are owned by the server."""
import asyncio
from datetime import datetime, timezone
from fastapi import HTTPException
from services import history_service, operation_service
from services.paths_service import DATA_DIR

_locks = {}


def conversation_dir(chat_id, role_id):
    return DATA_DIR / ("groups" if chat_id != role_id else "roles") / chat_id / "chats"


def message(identity, sender, content):
    return {"id": identity, "sender_id": sender, "receiver_id": "me" if sender != "me" else "ai",
            "content": content, "type": "text", "timestamp": datetime.now(timezone.utc).isoformat()}


async def execute(event):
    received_user = message(event.request_id + "_user", "me", event.content or "")
    from routers import ai_behavior as behavior
    role = behavior.load_role(event.role_id)
    if role is None:
        raise HTTPException(404, "角色不存在")
    chat_id = (event.context or {}).get("chat_id") or event.role_id
    if not isinstance(chat_id, str) or not chat_id.replace("_", "").replace("-", "").isalnum():
        raise HTTPException(422, "无效会话编号")
    if chat_id != event.role_id:
        from routers.groups import load
        if event.role_id not in load(chat_id).member_ids:
            raise HTTPException(403, "角色不是群聊成员")
        if event.event_type == behavior.AIEventType.CHAT:
            raise HTTPException(422, "群聊请使用统一群聊回合接口")
    key = "event:" + event.request_id
    operation_service.claim(key, event.model_dump(mode="json"))
    async with _locks.setdefault(chat_id, asyncio.Lock()):
        try:
            from services import behavior_service as autonomy
            channel = event.event_type.value
            if channel in ("proactive", "moment", "comment"):
                reason = autonomy.gate(event.role_id, channel, key, reserve=True)
                if reason != "ready":
                    operation_service.finish(key)
                    from services.logging_service import get_logger, reference
                    get_logger("behavior").info("", extra={"event": "behavior_paused_" + reason,
                                                           "role_ref": reference(event.role_id)})
                    return behavior.AIResponse(success=True, action="ignore", metadata={"reason": reason})
                with autonomy.optional(event.role_id, channel, key):
                    result = await behavior.process_ai_event(event)
            else:
                result = await behavior.process_ai_event(event)
            if not result.success:
                operation_service.finish(key, operation_service.failure_state(result.error))
                return result
            if channel in ("proactive", "moment", "comment"):
                # A slow provider may cross a quiet-window boundary or switch change.
                reason = autonomy._rule(event.role_id, channel)
                if reason != "ready":
                    operation_service.finish(key)
                    return behavior.AIResponse(success=True, action="ignore", metadata={"reason": reason})
            rows = []
            from services.tts_service import prepare, deliver
            voice_requested = False
            if result.content and result.action == "reply":
                result.content, voice_requested = prepare(result.content)
            if event.event_type == behavior.AIEventType.CHAT:
                user = received_user
                user.update(quote_id=event.quote_id, quote_content=event.quote_content)
                rows.append(user)
            if result.content and result.action == "reply":
                from services.delivery_service import replies
                rows.extend(replies(event.request_id, event.role_id, result.content))
            if rows:
                await deliver(conversation_dir(chat_id, event.role_id), rows, voice_requested)
                result.metadata = {**(result.metadata or {}), "messages": rows}
                if channel == "proactive":
                    from services.memory_service import append_short_term
                    append_short_term(event.role_id, "assistant", result.content)
            if result.content and result.action == "post":
                from routers.moments import create_moment, MomentCreate
                post = await create_moment(MomentCreate(author_id=event.role_id,
                    author_name=role.get("name", ""), content=result.content))
                result.metadata = {**(result.metadata or {}), "post_id": post["id"]}
            if result.content and result.action == "comment" and (event.context or {}).get("post_id"):
                from routers.moments import add_comment, CommentCreate
                await add_comment(event.context["post_id"], CommentCreate(author_id=event.role_id,
                    id=event.request_id, author_name=role.get("name", ""), content=result.content,
                    reply_to_id=event.context.get("reply_to_id"), reply_to_name=event.context.get("reply_to_name")))
            operation_service.finish(key)
            if event.event_type == behavior.AIEventType.CHAT:
                autonomy.user_contact(event.role_id)
                from services.memory_service import trigger_memory_summary
                try:
                    await trigger_memory_summary(event.role_id, role)
                except Exception:
                    from services.logging_service import get_logger
                    get_logger("memory").exception("", extra={"event": "summary_failed_after_delivery"})
            return result
        except BaseException:
            # Claimed/uncertain operations are never automatically replayed.
            operation_service.finish(key, "uncertain")
            raise
