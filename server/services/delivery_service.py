"""Stable message identities for text segments, stickers and private images."""
import base64
from datetime import datetime, timedelta, timezone
from pathlib import Path
import random
import re
from fastapi import APIRouter, HTTPException, Request
from pydantic import Field
from services.resource_service import resource_response, version
from services.paths_service import DATA_DIR

router = APIRouter()
EMOTIONS = {"happy", "sad", "angry", "surprised", "love", "confused", "excited", "tired"}


def replies(identity, role_id, content):
    from services.event_service import message
    rows = []
    # Windows clock resolution can give the preceding user row the same instant;
    # use a later sort key so assistant/user IDs cannot reverse the display order.
    now = datetime.now(timezone.utc) + timedelta(milliseconds=1)
    for index, segment in enumerate(part.strip() for part in content.split("$") if part.strip()):
        match = re.search(r"\[(\w+)\]", segment)
        emotion = match[1] if match and match[1] in EMOTIONS else None
        cleaned = segment.replace(match[0], "", 1).strip() if emotion else segment
        if cleaned:
            row = message(identity + ("_assistant" if not rows else f"_assistant_{len(rows)}"), role_id, cleaned)
            row["timestamp"] = (now + timedelta(milliseconds=len(rows))).isoformat()
            rows.append(row)
        if emotion:
            root = DATA_DIR / "roles" / role_id / "emojis" / emotion
            files = [p for p in root.iterdir() if p.is_file() and p.suffix.lower() in (".png", ".jpg", ".jpeg", ".gif", ".webp")] if root.exists() else []
            if files:
                chosen = random.choice(files)
                url = f"/api/emojis/{role_id}/{emotion}/{chosen.name}?v={version(chosen)}"
                row = message(identity + f"_assistant_{len(rows)}", role_id, f"[STICKER:{emotion}:{url}]")
                row["type"] = "sticker"
                row["timestamp"] = (now + timedelta(milliseconds=len(rows))).isoformat()
                rows.append(row)
    return rows


def save_image(identity, image_base64, mime):
    data = validate_image(image_base64)
    return store_image(identity, data, mime)


def validate_image(image_base64):
    try:
        data = base64.b64decode(image_base64, validate=True)
    except ValueError:
        raise HTTPException(422, "图片编码无效")
    if len(data) > 9 * 1024 * 1024:
        raise HTTPException(413, "图片过大")
    if not data:
        raise HTTPException(422, "图片不能为空")
    return data


def store_image(identity, data, mime):
    extension = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}[mime]
    # Identity is hashed, never interpreted as a filesystem path.
    import hashlib
    name = hashlib.sha256(identity.encode()).hexdigest() + "." + extension
    root = DATA_DIR / "images"
    root.mkdir(parents=True, exist_ok=True)
    target = root / name
    if not target.exists():
        with target.open("xb") as stream:
            stream.write(data)
    return "/api/images/" + name


@router.get("/images/{name}")
async def image(name: str, request: Request):
    if not re.fullmatch(r"[a-f0-9]{64}\.(png|jpg|webp)", name):
        raise HTTPException(404, "图片不存在")
    path = DATA_DIR / "images" / name
    if not path.is_file():
        raise HTTPException(404, "图片不存在")
    return resource_response(path, request)
