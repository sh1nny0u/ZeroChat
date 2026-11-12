"""Bounded image ingestion; validate before changing any resource or profile."""
import asyncio
from pathlib import Path
from fastapi import HTTPException

MAX_IMAGE_BYTES = 9 * 1024 * 1024


def validate(content, extension):
    extension = extension.lower().lstrip('.')
    valid = (
        extension in ('jpg', 'jpeg') and content.startswith(b'\xff\xd8\xff') or
        extension == 'png' and content.startswith(b'\x89PNG\r\n\x1a\n') or
        extension == 'gif' and content[:6] in (b'GIF87a', b'GIF89a') or
        extension == 'webp' and content[:4] == b'RIFF' and content[8:12] == b'WEBP'
    )
    if not valid:
        raise HTTPException(422, '图片内容与格式不符，原资源未修改')


async def image(file):
    extension = Path(file.filename or '').suffix.lower().lstrip('.')
    if extension not in ('jpg', 'jpeg', 'png', 'gif', 'webp'):
        raise HTTPException(422, '仅支持 JPG、PNG、GIF、WebP 图片')
    try:
        content = await asyncio.wait_for(file.read(MAX_IMAGE_BYTES + 1), timeout=20)
    except asyncio.TimeoutError:
        raise HTTPException(408, '图片读取超时，请重新选择后手动重试')
    if len(content) > MAX_IMAGE_BYTES:
        raise HTTPException(413, '图片超过 9 MiB 上限，原资源未修改')
    validate(content, extension)
    return content, extension
