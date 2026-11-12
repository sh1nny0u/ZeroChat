from fastapi import APIRouter, Request
from pydantic import BaseModel, Field
from services import auth_service as auth

router = APIRouter()


class Login(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)
    device: str = Field(default="新设备", max_length=100)


class Setup(Login):
    username: str = Field(min_length=6, max_length=14)
    password: str = Field(min_length=6, max_length=14)
    setup_token: str = Field(min_length=1, max_length=256)


class PasswordChange(BaseModel):
    old_password: str = Field(min_length=1, max_length=256)
    new_password: str = Field(min_length=6, max_length=14)


@router.get("/auth/status")
def status():
    return {"initialized": auth.initialized(), "protocol_version": 9,
            "min_client_protocol": 9, "capabilities": ['origin_credentials', 'tts_reconcile', 'notification_poll', 'persistent_sessions']}


@router.post("/auth/setup")
def setup(body: Setup, request: Request):
    return auth.setup(**body.model_dump(), peer=request.client.host)


@router.post("/auth/login")
def login(body: Login, request: Request):
    return auth.login(**body.model_dump(), peer=request.client.host)


@router.get("/auth/me")
def me(request: Request):
    return request.state.auth


@router.get("/auth/sessions")
def sessions(request: Request):
    return {"sessions": auth.sessions(request.state.auth["session_id"])}


@router.delete("/auth/sessions/{session_id}")
def revoke(session_id: str):
    auth.revoke(session_id)
    return {"success": True}


@router.post("/auth/logout")
def logout(request: Request):
    auth.revoke(request.state.auth["session_id"])
    return {"success": True}


@router.post("/auth/password")
def password(body: PasswordChange, request: Request):
    auth.change_password(body.old_password, body.new_password, request.state.auth["session_id"])
    return {"success": True}
