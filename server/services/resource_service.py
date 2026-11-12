"""Conditional private resources: unversioned URLs are revalidated, never frozen."""
from pathlib import Path
from fastapi import Request
from fastapi.responses import FileResponse, Response


def version(path: Path):
    stat = path.stat()
    return f"{stat.st_mtime_ns:x}-{stat.st_size:x}"


def resource_response(path: Path, request: Request):
    etag = '"' + version(path) + '"'
    # no-cache is deliberate: max-age=0 is ignored by older cache clients.
    headers = {"ETag": etag, "Cache-Control": "private, no-cache",
               "Vary": "Authorization"}
    candidates = {item.strip().removeprefix("W/") for item in
                  request.headers.get("if-none-match", "").split(",")}
    if etag in candidates or "*" in candidates:
        return Response(status_code=304, headers=headers)
    return FileResponse(path, headers=headers)
