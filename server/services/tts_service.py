"""TTS policy, durable reservations and delivery; providers never own messages."""
import asyncio
import base64
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import time
from typing import Protocol
import uuid
import wave

import httpx
from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from services import operation_service, settings_service, sync_service
from services.logging_service import get_logger, reference

ENDPOINT = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
SAMPLE_RATE = 24000
MAX_AUDIO_BYTES = SAMPLE_RATE * 2 * 180
logger = get_logger("tts")


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    enabled: bool = False
    provider: str = Field(default="doubao", pattern=r"^doubao$")
    speaker: str = Field(default="zh_female_vv_uranus_bigtts", pattern=r"^[A-Za-z0-9_-]{1,160}$")
    resource_id: str = Field(default="seed-tts-2.0", pattern=r"^(seed-tts-2.0|seed-icl-2.0)$")
    speech_rate: int = Field(default=0, ge=-50, le=100)
    min_interval_seconds: int = Field(default=60, ge=0, le=86400)
    daily_calls: int = Field(default=30, ge=0, le=1000)
    daily_characters: int = Field(default=6000, ge=0, le=1000000)
    max_characters: int = Field(default=300, ge=1, le=1000)
    timeout_seconds: int = Field(default=20, ge=2, le=60)


def config(role_id=None):
    kind, key = ("tts_config", role_id) if role_id else ("tts_policy", "global")
    path = sync_service.entity_path(kind, key)
    saved = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if role_id:
        return {"inherit": True, "config": Config().model_dump()} | saved
    return Config(**saved).model_dump()


def validate(kind, key, payload):
    try:
        if kind == "tts_policy":
            if key != "global":
                raise ValueError()
            return Config(**payload).model_dump()
        require_role(key)
        if set(payload) != {"inherit", "config"} or type(payload["inherit"]) is not bool:
            raise ValueError()
        return {"inherit": payload["inherit"], "config": Config(**payload["config"]).model_dump()}
    except (ValueError, TypeError, ValidationError):
        raise HTTPException(422, "语音设置无效，请检查开关、音色和额度")


def require_role(role_id):
    from routers.ai_behavior import load_role
    sync_service.identity(role_id)
    if not load_role(role_id):
        raise HTTPException(404, "目标角色不存在")


def effective(role_id=None):
    global_config = config()
    if not role_id:
        return global_config
    require_role(role_id)
    own = config(role_id)
    selected = global_config if own["inherit"] else Config(**own["config"]).model_dump()
    # The global switch is a master gate, including roles with custom voices.
    return {**selected, "enabled": global_config["enabled"] and selected["enabled"]}


def credentials(role_id=None):
    store = settings_service.load_settings().get("tts_credentials", {})
    if role_id and not config(role_id)["inherit"]:
        # An override uses its own secret, or explicitly inherits the same provider's key.
        return store.get(role_id, {}).get("api_key") or store.get("global", {}).get("api_key", "")
    return store.get("global", {}).get("api_key", "")


def credential_state(role_id=None):
    entry = settings_service.load_settings().get("tts_credentials", {}).get(role_id or "global", {})
    return {"revision": entry.get("revision"), "api_key_configured": bool(entry.get("api_key")),
            "ready": bool(credentials(role_id))}


def save_credential(role_id, api_key, revision):
    if role_id:
        require_role(role_id)
    with sync_service.LOCK:
        store = dict(settings_service.load_settings().get("tts_credentials", {}))
        entry = store.get(role_id or "global", {})
        if entry.get("revision") != revision:
            raise HTTPException(409, "语音凭证已在其他设备修改，请重新载入")
        store[role_id or "global"] = {"api_key": api_key.strip(), "revision": uuid.uuid4().hex}
        if not settings_service.save_settings({"tts_credentials": store}):
            raise HTTPException(500, "语音凭证保存失败，请手动重试")
    logger.info("", extra={"event": "tts_credential_saved", "role_ref": reference(role_id or "global")})
    return credential_state(role_id)


def tables(db):
    db.execute("""CREATE TABLE IF NOT EXISTS tts_calls(
      id TEXT PRIMARY KEY, role_id TEXT, day TEXT, characters INTEGER, created REAL)""")


def day():
    from services.behavior_service import policy
    offset = policy()["utc_offset_minutes"]
    return datetime.now(timezone(timedelta(minutes=offset))).date().isoformat()


def usage(role_id=None):
    with operation_service.database() as db:
        tables(db)
        where, args = (" AND role_id=?", (day(), role_id)) if role_id else ("", (day(),))
        row = db.execute("SELECT COUNT(*), COALESCE(SUM(characters),0) FROM tts_calls WHERE day=?" + where, args).fetchone()
        return {"calls": row[0], "characters": row[1]}


def read(role_id=None):
    if role_id:
        require_role(role_id)
    kind, key = ("tts_config", role_id) if role_id else ("tts_policy", "global")
    value = config(role_id)
    return {"value": value, "version": sync_service.version(kind, key), "effective": effective(role_id),
            "credentials": credential_state(role_id), "usage": usage(role_id), "global_usage": usage()}


def reserve(identity, role_id, text, selected):
    global_config = config()
    now, today = time.time(), day()
    with operation_service.database() as db:
        tables(db)
        if db.execute("SELECT 1 FROM tts_calls WHERE id=?", (identity,)).fetchone():
            return "duplicate"
        for scope, limits in ((None, global_config), (role_id, selected)):
            where, args = (" AND role_id=?", (today, scope)) if scope else ("", (today,))
            count, characters = db.execute("SELECT COUNT(*), COALESCE(SUM(characters),0) FROM tts_calls WHERE day=?" + where, args).fetchone()
            if count >= limits["daily_calls"] or characters + len(text) > limits["daily_characters"]:
                return "budget"
        global_last = db.execute("SELECT MAX(created) FROM tts_calls").fetchone()[0]
        if global_last is not None and now - global_last < global_config["min_interval_seconds"]:
            return "frequency"
        last = db.execute("SELECT MAX(created) FROM tts_calls WHERE role_id=?", (role_id,)).fetchone()[0]
        if last is not None and now - last < max(global_config["min_interval_seconds"], selected["min_interval_seconds"]):
            return "frequency"
        db.execute("INSERT INTO tts_calls VALUES (?,?,?,?,?)", (identity, role_id, today, len(text), now))
    return "ready"


@dataclass(frozen=True)
class Audio:
    data: bytes
    duration_ms: int


class Provider(Protocol):
    async def synthesize(self, text: str, selected: dict, api_key: str) -> Audio: ...


class DoubaoProvider:
    """HTTP V3 JSON-lines PCM, assembled once into a seekable mono WAV."""
    async def synthesize(self, text, selected, api_key):
        pcm = bytearray()
        completed = False
        async with httpx.AsyncClient(timeout=selected["timeout_seconds"], follow_redirects=False) as client:
            async with client.stream("POST", ENDPOINT, headers={
                "X-Api-Key": api_key, "X-Api-Resource-Id": selected["resource_id"],
                "X-Api-Request-Id": str(uuid.uuid4()), "Content-Type": "application/json",
            }, json={"req_params": {"text": text, "speaker": selected["speaker"], "audio_params": {
                "format": "pcm", "sample_rate": SAMPLE_RATE, "speech_rate": selected["speech_rate"]}}}) as response:
                response.raise_for_status()
                buffer = bytearray()
                wire_size = 0
                async for chunk in response.aiter_bytes():
                    wire_size += len(chunk)
                    if wire_size > MAX_AUDIO_BYTES * 2:
                        raise ValueError("oversized response")
                    buffer.extend(chunk)
                    while b"\n" in buffer:
                        line, _, remaining = buffer.partition(b"\n")
                        buffer = bytearray(remaining)
                        if line.strip():
                            completed = self._packet(line, pcm) or completed
                if buffer.strip():
                    completed = self._packet(buffer, pcm) or completed
        if not completed or not pcm or len(pcm) % 2:
            raise ValueError("incomplete audio")
        stream = io.BytesIO()
        with wave.open(stream, "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(SAMPLE_RATE)
            output.writeframes(pcm)
        return Audio(stream.getvalue(), max(1, round(len(pcm) / (SAMPLE_RATE * 2) * 1000)))

    @staticmethod
    def _packet(line, pcm):
        packet = json.loads(line)
        code = packet.get("code")
        if code not in (0, 20000000):
            raise ValueError("provider rejected")
        if packet.get("data"):
            pcm.extend(base64.b64decode(packet["data"], validate=True))
            if len(pcm) > MAX_AUDIO_BYTES:
                raise ValueError("oversized audio")
        # Current HTTP V3 returns code=0 audio packets and clean EOF. Legacy
        # HTTP V3 also emits a 20000000 terminal packet; accept both contracts.
        return code in (0, 20000000)


PROVIDERS: dict[str, Provider] = {"doubao": DoubaoProvider()}


def prompt(role_id):
    try:
        selected = effective(role_id)
        if selected["enabled"] and credentials(role_id):
            return "\n你可按情境决定是否用语音表达。适合简短口语时在回复最前面加[语音]，其余时候直接回复文字。不要向用户解释这个标记；语音内容也须完整写出。"
    except (HTTPException, ValueError):
        pass
    return ""


def prepare(content):
    # Always remove the control token, including when an inherited switch was changed mid-call.
    requested = content.lstrip().startswith("[语音]")
    return content.replace("[语音]", "").strip(), requested


async def synthesize(identity, role_id, text, *, test=False):
    selected = effective(role_id)
    reason = "disabled"
    if (selected["enabled"] or test) and text:
        reason = "not_configured" if not credentials(role_id) else "too_long" if len(text) > selected["max_characters"] else reserve(identity, role_id or "global", text, selected)
    if reason != "ready":
        log_reason(role_id, reason)
        return {"status": reason}
    try:
        # One attempt, one explicitly selected provider; no retry or provider substitution.
        audio = await asyncio.wait_for(PROVIDERS[selected["provider"]].synthesize(text, selected, credentials(role_id)),
                                       timeout=selected["timeout_seconds"])
        if not 0 < len(audio.data) <= MAX_AUDIO_BYTES + 4096 or not 0 < audio.duration_ms <= 180000:
            raise ValueError("invalid audio")
        # Validate provider adapters before storing a private resource.
        with wave.open(io.BytesIO(audio.data), "rb") as check:
            if check.getnframes() <= 0 or check.getcomptype() != "NONE":
                raise ValueError("invalid wave")
            duration = round(check.getnframes() / check.getframerate() * 1000)
        name = hashlib.sha256(identity.encode()).hexdigest() + ".wav"
        root = operation_service.DATA_DIR / "audio"
        root.mkdir(parents=True, exist_ok=True)
        target = root / name
        with target.open("xb") as output:
            output.write(audio.data)
        return {"status": "ready", "audio_url": "/api/audio/" + name, "duration_ms": max(1, duration)}
    except (TimeoutError, httpx.TimeoutException):
        reason = "timeout"
    except asyncio.CancelledError:
        log_reason(role_id, "cancelled")
        raise
    except Exception:
        # Do not log provider response bodies, exceptions, text, keys or audio.
        reason = "provider_failed"
    log_reason(role_id, reason)
    return {"status": reason}


def log_reason(role_id, reason):
    extra = {"event": "tts_" + reason, "role_ref": reference(role_id or "global")}
    if reason in ("timeout", "provider_failed", "configuration_failed", "delivery_failed"):
        extra["error_type"] = reason
        logger.warning("", extra=extra)
    else:
        logger.info("", extra=extra)


async def deliver(directory, rows, requested):
    """Persist text first. A crash, timeout or provider error cannot erase it."""
    from services import history_service
    history_service.append(directory, rows)
    candidates = [r for r in rows if r["sender_id"] != "me" and r["type"] == "text"]
    if not requested or not candidates:
        return
    # One voice per model turn; do not multiply charges for split message bubbles.
    row = candidates[0]
    try:
        result = await synthesize("voice:" + row["id"], row["sender_id"], row["content"])
    except Exception:
        log_reason(row["sender_id"], "configuration_failed")
        return
    if result["status"] == "ready":
        try:
            history_service.attach_audio(directory, row["id"], result["audio_url"], result["duration_ms"])
            row.update(type="voice", audio_url=result["audio_url"], duration_ms=result["duration_ms"])
        except Exception:
            log_reason(row["sender_id"], "delivery_failed")
