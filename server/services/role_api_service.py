"""Role providers live only in the protected server settings, never in profiles."""
import uuid
from urllib.parse import urlsplit

from fastapi import HTTPException
from services import settings_service
from services.logging_service import get_logger, reference

STORE = "role_api_credentials"


def validate_url(value):
    if not value:
        return
    try:
        parsed = urlsplit(value)
        if (parsed.scheme not in ("https", "http") or not parsed.hostname or parsed.username
                or parsed.password or parsed.query or parsed.fragment or parsed.netloc.endswith(":")):
            raise ValueError()
        parsed.port
    except ValueError:
        raise HTTPException(422, "API 地址须为 HTTP/HTTPS 地址，不能包含凭证、查询参数或片段")


def origin(value):
    parsed = urlsplit(value)
    return parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)


def resolve(role_id, config=None):
    config = config if config is not None else settings_service.load_settings()
    own = config.get(STORE, {}).get(role_id, {})
    url = own.get("api_url") or config.get("ai_api_url", "")
    global_url = config.get("ai_api_url", "")
    # An inherited key must never travel to an unrelated provider origin.
    inherited_key = settings_service.provider_config(config)['api_key'] if not own.get("api_url") or origin(url) == origin(global_url) else ""
    own_key = own.get("api_key") or ""
    if own_key and own.get("key_origin") and own["key_origin"] != list(origin(url)):
        own_key = ""
    return {"api_url": url, "api_key": own_key or inherited_key,
            "model": own.get("model") or config.get("ai_model", "gpt-3.5-turbo")}


def read(role_id):
    config = settings_service.load_settings()
    own = config.get(STORE, {}).get(role_id, {})
    effective = resolve(role_id, config)
    return {"role_id": role_id, "revision": own.get("revision"), "api_url": own.get("api_url", ""),
            "model": own.get("model", ""), "api_key_configured": bool(own.get("api_key")),
            "effective_url": effective["api_url"], "effective_model": effective["model"],
            "ready": bool(effective["api_url"] and effective["api_key"])}


def save(role_id, values):
    from services.sync_service import LOCK
    with LOCK:
        return _save(role_id, values)


def _save(role_id, values):
    config = settings_service.load_settings()
    entries = dict(config.get(STORE, {}))
    current = entries.get(role_id, {})
    if values.pop("revision", None) != current.get("revision"):
        raise HTTPException(409, "角色 API 已在其他设备修改，请重新载入后再保存")
    values = {k: v.strip() if isinstance(v, str) else v for k, v in values.items() if v is not None}
    updated = {**current, **values, "revision": uuid.uuid4().hex}
    validate_url(updated.get("api_url", ""))
    old_url = current.get("api_url") or config.get("ai_api_url", "")
    new_url = updated.get("api_url") or config.get("ai_api_url", "")
    if "api_key" not in values and origin(old_url) != origin(new_url):
        updated["api_key"] = ""
    if values.get("api_key"):
        updated["key_origin"] = list(origin(new_url))
    entries[role_id] = updated
    if not settings_service.save_settings({STORE: entries}):
        raise HTTPException(500, "角色 API 保存失败，请手动重试")
    get_logger("settings").info("", extra={"event": "role_api_saved", "role_ref": reference(role_id)})
    return read(role_id)


def migrate_legacy():
    """Protect legacy provider overrides before sync projects public profiles."""
    from routers import roles
    from services import backup_service, sync_service
    fields = {"ai_api_url": "api_url", "ai_api_key": "api_key", "ai_model": "model",
              "api_url": "api_url", "api_key": "api_key", "model": "model",
              "chat_api_url": "api_url", "chat_api_key": "api_key", "chat_model": "model"}
    pending, warnings = [], []
    for path in roles.ROLES_DIR.glob("*/profile.json"):
        import json
        try:
            profile = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(profile, dict) or profile.get("id") != path.parent.name:
                raise ValueError()
            sync_service.identity(profile["id"])
        except (ValueError, OSError, TypeError, HTTPException):
            warnings.append({"id": path.parent.name, "reason": "无法可靠识别，原始资料保留"})
            continue
        legacy = {target: profile[source] for source, target in fields.items() if isinstance(profile.get(source), str)}
        for name in ("chat_api_config", "api_config"):
            nested = profile.get(name)
            if isinstance(nested, dict):
                legacy.update({k: nested[k] for k in ("api_url", "api_key", "model") if isinstance(nested.get(k), str)})
        if legacy:
            pending.append((path, profile, legacy))
    report_path = roles.ROLES_DIR.parent / "migration-role-api-v5.json"
    if not pending:
        if warnings:
            previous = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}
            sync_service.write_json(report_path, {**previous, "warnings": warnings, "originals_retained": True})
        return
    backup = backup_service.create(internal=True)
    config = settings_service.load_settings()
    entries = dict(config.get(STORE, {}))
    for path, profile, legacy in pending:
        entries[profile["id"]] = {**legacy, **entries.get(profile["id"], {}),
                                 "revision": entries.get(profile["id"], {}).get("revision") or uuid.uuid4().hex}
        entry = entries[profile["id"]]
        if entry.get("api_key"):
            entry.setdefault("key_origin", list(origin(entry.get("api_url") or config.get("ai_api_url", ""))))
    if not settings_service.save_settings({STORE: entries}):
        raise RuntimeError("Legacy role API protection failed; originals retained")
    for path, profile, _ in pending:
        for key in (*fields, "chat_api_config", "api_config"):
            profile.pop(key, None)
        sync_service.write_json(path, profile)
    sync_service.write_json(report_path, {"backup_id": backup["id"], "count": len(pending),
                            "originals_in_backup": True, "warnings": warnings})
    get_logger("migration").info("", extra={"event": "role_api_migrated", "count": len(pending)})
