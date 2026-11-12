"""Read-only Android delivery cursor; never invokes AI or returns message text."""
from fastapi import APIRouter
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from services import sync_service, history_service, settings_service

router = APIRouter()


class Poll(BaseModel):
    cursors: dict[str, int] = Field(default_factory=dict, max_length=5000)
    epoch: str | None = Field(default=None, max_length=64)


def read(cursors, epoch=None):
    from services.behavior_service import clock
    now = clock()
    settings = settings_service.load_settings()
    with sync_service.database() as db:
        current_epoch = db.execute("SELECT value FROM meta WHERE key='epoch'").fetchone()[0]
    if epoch != current_epoch:
        cursors = {}
    start, end = settings.get('quiet_start', 23), settings.get('quiet_end', 7)
    from services.behavior_service import policy, in_quiet
    behavior = policy()
    quiet = (settings.get('quiet_enabled', False) and in_quiet(now.hour, start, end) or
             behavior['quiet_enabled'] and in_quiet(now.hour, behavior['quiet_start'], behavior['quiet_end']))
    chats = []
    for kind in ('roles', 'groups'):
        for path in sorted((sync_service.DATA_DIR / kind).glob('*/profile.json')):
            import json
            profile = json.loads(path.read_text(encoding='utf-8'))
            if profile.get('deleted'):
                continue
            key = path.parent.name
            previous = cursors.get(key)
            page = history_service.page(path.parent / 'chats', limit=200, after=previous) if previous is not None else history_service.page(path.parent / 'chats', limit=1)
            incoming = [m['id'] for m in page['messages'] if m.get('sender_id') != 'me'] if previous is not None else []
            chats.append({'id': key, 'cursor': page['next_after'] if previous is not None else page['high_water'],
                          'incoming_ids': incoming, 'has_more': page['has_more'] if previous is not None else False})
    return {'chats': chats, 'quiet': quiet, 'epoch': current_epoch}


@router.post('/notifications/poll')
async def poll(body: Poll):
    return await run_in_threadpool(read, body.cursors, body.epoch)
