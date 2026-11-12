"""Protect every private route, including files and conditional responses."""
import os
from fastapi import HTTPException
from starlette.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from services import auth_service


class AccessMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path, method = scope["path"], scope["method"]
        try:
            if os.environ.get("ZEROCHAT_REQUIRE_HTTPS") == "1" and scope["scheme"] != "https":
                raise HTTPException(400, "此服务器仅接受 HTTPS，请检查服务器地址")
            if any(p in ("..", ".") or "\\" in p or "\x00" in p for p in path.split("/")):
                raise HTTPException(400, "无效资源路径")
            public = (method, path) in {("GET", "/"), ("GET", "/api/health"), ("GET", "/api/license"),
                ("GET", "/api/auth/status"), ("POST", "/api/auth/setup"), ("POST", "/api/auth/login")}
            if not public and method != "OPTIONS":
                header = dict(scope["headers"]).get(b"authorization", b"").decode("latin1")
                token = header[7:] if header.startswith("Bearer ") else ""
                scope.setdefault("state", {})["auth"] = await run_in_threadpool(auth_service.authenticate, token)
        except HTTPException as error:
            response = JSONResponse({"detail": error.detail}, error.status_code,
                                    headers={"Cache-Control": "no-store", **(error.headers or {})})
            return await response(scope, receive, send)
        async def private_send(message):
            if message["type"] == "http.response.start":
                headers = list(message["headers"])
                headers.extend([(b"x-content-type-options", b"nosniff"), (b"referrer-policy", b"no-referrer")])
                if path.startswith("/api/auth") or not (method in ("GET", "HEAD") and any(x in path for x in ("/file", "/emojis/", "/avatars/", "/audio/"))):
                    headers = [(k, v) for k, v in headers if k.lower() != b"cache-control"]
                    headers.append((b"cache-control", b"no-store"))
                if os.environ.get("ZEROCHAT_REQUIRE_HTTPS") == "1":
                    headers.append((b"strict-transport-security", b"max-age=31536000"))
                message = {**message, "headers": headers}
            await send(message)
        await self.app(scope, receive, private_send)
