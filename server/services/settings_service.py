"""
设置服务
管理全局配置（API URL、KEY、模型等）
"""
import json
import os
import uuid
from urllib.parse import urlsplit
from pathlib import Path
from typing import Optional, Dict, Any

from services.logging_service import get_logger

logger = get_logger("settings")
from services.paths_service import CONFIG_DIR

def get_settings_file() -> Path:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    return CONFIG_DIR / "settings.json"

def get_default_settings() -> Dict[str, Any]:
    """获取默认设置"""
    return {
        "host": "0.0.0.0",
        "port": 8000,
        "ai_api_url": "",
        "ai_api_key": "",
        "ai_model": "gpt-3.5-turbo",
        "updated_at": None
    }

def load_settings() -> Dict[str, Any]:
    """加载设置"""
    settings_file = get_settings_file()
    default = get_default_settings()
    
    if settings_file.exists():
        try:
            with open(settings_file, "r", encoding="utf-8") as f:
                saved = json.load(f)
                return {**default, **saved}
        except Exception:
            logger.exception("", extra={"event": "settings_load_failed"})
    
    return default

def save_settings(settings: Dict[str, Any]) -> bool:
    from services.sync_service import LOCK
    with LOCK:
        return _save_settings(settings)


def _save_settings(settings: Dict[str, Any]) -> bool:
    """保存设置"""
    try:
        settings_file = get_settings_file()
        
        # 合并现有设置
        current = load_settings()
        settings = dict(settings)
        for prefix in ('ai', 'intent', 'vision'):
            url_field, key_field = prefix + '_api_url', prefix + '_api_key'
            old_url = current.get(url_field, '')
            new_url = settings.get(url_field, old_url)
            if url_field in settings and provider_origin(old_url) != provider_origin(new_url) and key_field not in settings:
                settings[key_field] = ''
            if key_field in settings:
                settings[prefix + '_credential_origin'] = provider_origin(new_url) if settings[key_field] else None
            elif current.get(key_field) and prefix + '_credential_origin' not in current and prefix + '_credential_origin' not in settings:
                settings[prefix + '_credential_origin'] = provider_origin(old_url)
        current.update(settings)
        
        # 添加更新时间
        from datetime import datetime
        current["updated_at"] = datetime.now().isoformat()
        
        temporary = settings_file.with_name("settings.pending-" + uuid.uuid4().hex + ".json")
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump(current, stream, indent=2, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        if os.name != "nt":
            temporary.chmod(0o600)
        os.replace(temporary, settings_file)
        
        return True
    except Exception:
        logger.exception("", extra={"event": "settings_save_failed"})
        return False

def provider_origin(value):
    try:
        parsed = urlsplit(value or '')
        if parsed.scheme not in ('http', 'https') or not parsed.hostname:
            return None
        return [parsed.scheme, parsed.hostname.lower(), parsed.port or (443 if parsed.scheme == 'https' else 80)]
    except ValueError:
        return None


def provider_config(settings, purpose='chat'):
    prefix = purpose if purpose in ('intent', 'vision') else 'ai'
    model = settings.get(prefix + '_model') or settings.get('ai_model', 'gpt-3.5-turbo')
    if prefix != 'ai' and not any(settings.get(prefix + s) for s in ('_api_url', '_api_key')):
        prefix = 'ai'
    url = settings.get(prefix + '_api_url', '')
    key = settings.get(prefix + '_api_key', '')
    bound = settings.get(prefix + '_credential_origin')
    if prefix + '_credential_origin' in settings and bound != provider_origin(url):
        key = ''
    return {'api_url': url, 'api_key': key,
            'model': model}


def migrate_credentials():
    """Bind known legacy origins once, retaining an internal verified backup first."""
    from services import sync_service, backup_service
    report = sync_service.DATA_DIR / 'migration-provider-origin-v9.json'
    current = load_settings()
    missing = [p for p in ('ai', 'intent', 'vision') if current.get(p + '_api_key') and p + '_credential_origin' not in current]
    if not missing:
        return
    backup = backup_service.create(internal=True)
    updates = {p + '_credential_origin': provider_origin(current.get(p + '_api_url')) for p in missing}
    # An unparseable source cannot be trusted; its original key stays in the protected backup.
    for p in missing:
        if updates[p + '_credential_origin'] is None:
            updates[p + '_api_key'] = ''
    if not save_settings(updates):
        raise RuntimeError('Credential migration not saved; protected original retained')
    sync_service.write_json(report, {'version': 9, 'backup_id': backup['id'], 'purposes': missing,
        'confirmation_required': [p for p in missing if updates[p + '_credential_origin'] is None]})


def get_ai_config(purpose='chat') -> Dict[str, str]:
    """获取 AI API 配置"""
    settings = load_settings()
    return provider_config(settings, purpose)

def update_ai_config(api_url: Optional[str] = None, 
                     api_key: Optional[str] = None,
                     model: Optional[str] = None) -> bool:
    """更新 AI API 配置"""
    updates = {}
    if api_url is not None:
        updates["ai_api_url"] = api_url
    if api_key is not None:
        updates["ai_api_key"] = api_key
    if model is not None:
        updates["ai_model"] = model
    
    if updates:
        return save_settings(updates)
    return True
