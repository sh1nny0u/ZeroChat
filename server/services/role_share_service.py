"""Portable, bounded role definitions. No network lookup or executable payloads."""
import base64
import binascii
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone

from fastapi import HTTPException
from services import sync_service
from services.logging_service import get_logger, reference

PREFIX = "ZEROCHAT1."
MAX_DECODED = 256 * 1024
MAX_CODE = 350000
FIELDS = {"name", "description", "system_prompt", "attached_json_content"}
logger = get_logger("share")


def fingerprint(value):
    return hashlib.sha256(sync_service.encode(value).encode("utf-8")).hexdigest()


def validate_profile(value):
    if not isinstance(value, dict) or set(value) - FIELDS or not {"name", "description", "system_prompt"} <= set(value):
        raise ValueError()
    if any(not isinstance(v, str) for v in value.values()) or not value["name"].strip():
        raise ValueError()
    if len(value["name"]) > 128 or len(value["description"]) > 10000 or len(value["system_prompt"]) > 100000:
        raise ValueError()
    if "attached_json_content" in value:
        # Validate only; never interpret attachment contents as configuration.
        json.loads(value["attached_json_content"])
    return value


def decode(code):
    try:
        if not isinstance(code, str) or len(code) > MAX_CODE:
            raise ValueError()
        code = code.strip()
        if not code.startswith(PREFIX):
            raise ValueError()
        encoded = code[len(PREFIX):]
        raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
        if len(raw) > MAX_DECODED:
            raise ValueError()
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError()
                result[key] = value
            return result
        envelope = json.loads(raw, object_pairs_hook=unique)
        if (not isinstance(envelope, dict) or set(envelope) != {"format", "version", "share_id", "profile", "checksum"}
                or envelope["format"] != "zerochat-role" or type(envelope["version"]) is not int or envelope["version"] != 1
                or not isinstance(envelope["share_id"], str) or not re.fullmatch(r"[0-9a-f]{32}", envelope["share_id"])):
            raise ValueError()
        profile = validate_profile(envelope["profile"])
        body = {k: v for k, v in envelope.items() if k != "checksum"}
        if envelope["checksum"] != fingerprint(body):
            raise ValueError()
        return envelope, fingerprint(profile)
    except (ValueError, TypeError, KeyError, UnicodeDecodeError, RecursionError, binascii.Error):
        logger.warning("", extra={"event": "share_code_rejected", "error_type": "ValidationError"})
        raise HTTPException(422, "好友码无效、过大、版本不支持或校验失败，请检查完整文本")


def export(role_id, include_attachment=False):
    from routers.roles import load_role
    role = load_role(role_id)
    if not role:
        raise HTTPException(404, "角色不存在")
    profile = {key: role.get(key) or "" for key in ("name", "description", "system_prompt")}
    if include_attachment and role.get("attached_json_content"):
        profile["attached_json_content"] = role["attached_json_content"]
    try:
        validate_profile(profile)
    except (ValueError, TypeError, RecursionError):
        raise HTTPException(422, "角色字段或外挂 JSON 无效，请先修正内容")
    # A random lineage survives edits without disclosing the original role ID.
    metadata = dict(role.get("metadata") or {})
    share_id = metadata.get("share_lineage")
    if not isinstance(share_id, str) or not re.fullmatch(r"[0-9a-f]{32}", share_id):
        share_id = uuid.uuid4().hex
    body = {"format": "zerochat-role", "version": 1, "share_id": share_id, "profile": profile}
    raw = sync_service.encode({**body, "checksum": fingerprint(body)}).encode("utf-8")
    if len(raw) > MAX_DECODED:
        raise HTTPException(413, "角色设定超过好友码 256 KiB 限制")
    if metadata.get("share_lineage") != share_id:
        result = sync_service.mutate({"operation_id": uuid.uuid4().hex, "kind": "role", "id": role_id,
            "base_version": sync_service.version("role", role_id, payload=role),
            "payload": {**role, "metadata": {**metadata, "share_lineage": share_id}}})
        if result["status"] != "applied":
            raise HTTPException(409, "角色已修改，请重新导出")
    logger.info("", extra={"event": "role_exported", "role_ref": reference(role_id)})
    return {"code": PREFIX + base64.urlsafe_b64encode(raw).decode("ascii").rstrip("="), "profile": profile,
            "warning": "编码不是加密，接收者可读取和修改全部人设；发出后无法撤回，原角色修改不会自动更新副本。外挂 JSON 可能含私人记录。"}


def preview(code):
    envelope, digest = decode(code)
    profile, share_id = envelope["profile"], envelope["share_id"]
    from routers.roles import ROLES_DIR, load_role
    matches = []
    for path in ROLES_DIR.glob("*/profile.json"):
        role = load_role(path.parent.name)
        if not role:
            continue
        metadata = role.get("metadata") or {}
        current = {key: role.get(key) or "" for key in profile}
        if (metadata.get("import_share_id") == share_id or metadata.get("share_lineage") == share_id
                or digest in metadata.get("import_fingerprints", []) or fingerprint(current) == digest):
            matches.append({"id": role["id"], "name": role["name"],
                "version": sync_service.version("role", role["id"], payload=role),
                "differences": {key: {"before": current[key], "after": value}
                                for key, value in profile.items() if current[key] != value}})
    logger.info("", extra={"event": "role_import_previewed", "count": len(matches)})
    return {"profile": profile, "fingerprint": digest, "matches": matches,
            "warning": "请核对完整人设和外挂 JSON。导入的角色独立运行，API 继承本机后端全局配置；同名不代表重复。"}


def import_role(values):
    envelope, digest = decode(values["code"])
    operation_id = values["operation_id"]
    # Receipt identity includes the whole user decision; retries cannot create copies.
    request_hash = fingerprint(values)
    sync_service.recover_pending()
    with sync_service.database() as db:
        receipt = db.execute("SELECT * FROM receipts WHERE id=?", ("share:" + operation_id,)).fetchone()
        if receipt:
            result = json.loads(receipt["result"])
            if result.get("share_request_hash") != request_hash:
                raise HTTPException(409, "导入操作编号已用于其他内容，请重新预览")
            return result
    examined = preview(values["code"])
    mode = values["mode"]
    profile = envelope["profile"]
    from routers.roles import RoleCreate, load_role
    if mode == "create" and examined["matches"]:
        raise HTTPException(409, "检测到重复，请取消、另存为新角色或预览差异后更新")
    if mode == "update":
        match = next((m for m in examined["matches"] if m["id"] == values.get("target_id")), None)
        if not match or not values.get("base_version") or match["version"] != values["base_version"]:
            raise HTTPException(409, "目标角色或版本已变化，请重新预览差异")
        role_id = match["id"]
        role = load_role(role_id)
        # Only fields present in this code are updated; omitted attachments survive.
        payload = {**role, **profile}
        base = match["version"]
    else:
        role_id = uuid.uuid5(uuid.NAMESPACE_URL, "zerochat-share:" + operation_id).hex
        base = None
        payload = RoleCreate(id=role_id, **profile).model_dump(exclude_none=True)
        payload.update(temperature=0.7, top_p=1.0, frequency_penalty=0.0,
                       presence_penalty=0.0, max_context_rounds=10, allow_web_search=True)
        payload["created_at"] = datetime.now(timezone.utc).isoformat()
    payload["updated_at"] = datetime.now(timezone.utc).isoformat()
    metadata = dict(payload.get("metadata") or {})
    fingerprints = list(metadata.get("import_fingerprints", []))
    if digest not in fingerprints:
        fingerprints.append(digest)
    payload["metadata"] = {**metadata, "import_share_id": envelope["share_id"], "import_fingerprints": fingerprints}
    result = sync_service.mutate({"operation_id": "share:" + operation_id, "kind": "role", "id": role_id,
                                  "base_version": base, "payload": payload}, {"share_request_hash": request_hash})
    if result["status"] != "applied":
        raise HTTPException(409, "角色版本冲突，请重新预览后重试")
    logger.info("", extra={"event": "role_imported", "role_ref": reference(role_id)})
    return result
