"""Private voice configuration, explicit paid test and authenticated resources."""
import re
import hashlib
import wave
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from services import tts_service as tts, operation_service
from services.resource_service import resource_response

router = APIRouter()


class Credential(BaseModel):
    api_key: str = Field(max_length=4096)
    revision: str | None = Field(default=None, max_length=64)


class Test(BaseModel):
    request_id: str = Field(min_length=8, max_length=128)
    text: str = Field(default="你好，这是一个语音测试。", min_length=1, max_length=300)


@router.get("/tts/global")
async def global_config():
    return await run_in_threadpool(tts.read)


@router.get("/tts/roles/{role_id}")
async def role_config(role_id: str):
    return await run_in_threadpool(tts.read, role_id)


@router.put("/tts/global/credentials")
async def global_credentials(body: Credential):
    return await run_in_threadpool(tts.save_credential, None, body.api_key, body.revision)


@router.put("/tts/roles/{role_id}/credentials")
async def role_credentials(role_id: str, body: Credential):
    return await run_in_threadpool(tts.save_credential, role_id, body.api_key, body.revision)


async def test_voice(body, role_id=None):
    if role_id:
        tts.require_role(role_id)
    identity = "tts-test:" + body.request_id
    operation_service.claim(identity, {"role_id": role_id, "text": body.text})
    try:
        result = await tts.synthesize(identity, role_id, body.text, test=True)
        operation_service.finish(identity, "completed" if result["status"] == "ready" else "failed")
        return result
    except BaseException:
        operation_service.finish(identity, "uncertain")
        raise


@router.post("/tts/global/test")
async def global_test(body: Test):
    return await test_voice(body)


@router.post("/tts/roles/{role_id}/test")
async def role_test(role_id: str, body: Test):
    return await test_voice(body, role_id)


@router.get('/tts/test-results/{request_id}')
async def test_result(request_id: str):
    if not re.fullmatch(r'[A-Za-z0-9_-]{8,128}', request_id):
        raise HTTPException(422, '无效测试请求编号')
    identity = 'tts-test:' + request_id
    state = operation_service.status(identity)
    name = hashlib.sha256(identity.encode()).hexdigest() + '.wav'
    path = operation_service.DATA_DIR / 'audio' / name
    if state == 'completed' and path.is_file():
        with wave.open(str(path), 'rb') as audio:
            duration = max(1, round(audio.getnframes() / audio.getframerate() * 1000))
        return {'state': state, 'status': 'ready', 'audio_url': '/api/audio/' + name, 'duration_ms': duration}
    return {'state': state, 'status': 'missing' if state == 'missing' else 'failed' if state == 'failed' else 'uncertain'}


@router.api_route("/audio/{name}", methods=["GET", "HEAD"])
async def audio(name: str, request: Request):
    if not re.fullmatch(r"[a-f0-9]{64}\.wav", name):
        raise HTTPException(404, "语音不存在")
    path = operation_service.DATA_DIR / "audio" / name
    if not path.is_file():
        raise HTTPException(404, "语音不存在，请确认备份包含音频")
    return resource_response(path, request)
