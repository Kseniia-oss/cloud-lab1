from collections import OrderedDict
from threading import Lock
from time import monotonic

from app.schemas import TaskOut

CACHE_TTL_SECONDS = 45
MAX_CACHE_ENTRIES = 256

CacheKey = tuple[int, bool | None]
_entries: OrderedDict[CacheKey, tuple[float, list[TaskOut]]] = OrderedDict()
_lock = Lock()


def read_tasks(key: CacheKey) -> list[TaskOut] | None:
    with _lock:
        entry = _entries.get(key)
        if entry is None:
            return None
        expires_at, tasks = entry
        if expires_at <= monotonic():
            del _entries[key]
            return None
        _entries.move_to_end(key)
        return tasks


def cache_tasks(key: CacheKey, tasks: list[TaskOut], started_at: float) -> None:
    expires_at = started_at + CACHE_TTL_SECONDS
    with _lock:
        current = _entries.get(key)
        if expires_at <= monotonic() or (current and current[0] >= expires_at):
            return
        _entries[key] = (expires_at, tasks)
        _entries.move_to_end(key)
        if len(_entries) > MAX_CACHE_ENTRIES:
            _entries.popitem(last=False)
