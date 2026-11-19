from time import monotonic

from app import tasks_cache


def test_expiry_and_empty_result():
    key = (100, None)
    expired_at = monotonic() - tasks_cache.CACHE_TTL_SECONDS - 1
    tasks_cache.cache_tasks(key, [], expired_at)
    assert tasks_cache.read_tasks(key) is None

    tasks_cache.cache_tasks(key, [], monotonic())
    assert tasks_cache.read_tasks(key) == []


def test_cache_keys_include_user_and_filter():
    tasks_cache.cache_tasks((201, True), [], monotonic())
    assert tasks_cache.read_tasks((201, True)) == []
    assert tasks_cache.read_tasks((201, False)) is None
    assert tasks_cache.read_tasks((202, True)) is None
