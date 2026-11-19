import logging
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from hashlib import sha256

from fastapi import HTTPException
from pydantic import BaseModel, ValidationError
from redis import Redis, RedisError
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import get_settings
from app.models import Task, TaskWriteReceipt
from app.schemas import TaskCreate, TaskOut

log = logging.getLogger(__name__)
RETENTION = timedelta(hours=24)


class WriteResult(BaseModel):
    expires_at: datetime
    payload_hash: str
    result: TaskOut


@lru_cache
def get_redis(url: str) -> Redis:
    return Redis.from_url(url, socket_connect_timeout=1, socket_timeout=1)


def replay(result: WriteResult, payload_hash: str) -> TaskOut:
    if result.payload_hash != payload_hash:
        raise HTTPException(409, "Idempotency-Key was used with a different payload")
    return result.result


def create_task_once(db: Session, owner_id: int, key: str, data: TaskCreate) -> TaskOut:
    url = get_settings().idempotency_redis_url
    if not url:
        raise HTTPException(503, "Idempotent writes are disabled")

    digest = sha256(f"{owner_id}:{key}".encode()).hexdigest()
    payload_hash = sha256(data.model_dump_json().encode()).hexdigest()
    redis_key = f"tasks-api:write:v1:{digest}"
    redis = get_redis(url)
    try:
        cached = redis.get(redis_key)
        if cached:
            result = WriteResult.model_validate_json(cached)
            if result.expires_at > datetime.now(UTC):
                return replay(result, payload_hash)
    except (RedisError, ValidationError):
        log.warning("Idempotency Redis lookup failed; using PostgreSQL")

    lock_id = int.from_bytes(bytes.fromhex(digest[:16]), "big", signed=True)
    db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": lock_id})
    receipt = db.get(TaskWriteReceipt, digest)
    now = datetime.now(UTC)
    if receipt is not None and receipt.expires_at > now:
        result = WriteResult.model_validate(receipt, from_attributes=True)
        replay(result, payload_hash)
    else:
        task = Task(title=data.title, description=data.description, owner_id=owner_id)
        db.add(task)
        db.flush()
        result = WriteResult(
            expires_at=now + RETENTION,
            payload_hash=payload_hash,
            result=TaskOut.model_validate(task),
        )
        if receipt is None:
            receipt = TaskWriteReceipt(key=digest)
            db.add(receipt)
        receipt.expires_at = result.expires_at
        receipt.payload_hash = result.payload_hash
        receipt.result = result.result.model_dump(mode="json")
    db.commit()

    ttl_ms = int((result.expires_at - datetime.now(UTC)).total_seconds() * 1000)
    if ttl_ms > 0:
        try:
            redis.set(redis_key, result.model_dump_json(), px=min(ttl_ms, 86_400_000))
        except RedisError:
            log.warning("Idempotency Redis write failed; receipt remains in PostgreSQL")
    return result.result
