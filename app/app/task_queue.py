from functools import lru_cache
from uuid import UUID

import boto3
from botocore.config import Config
from pydantic import BaseModel

from app.schemas import TaskCreate


class TaskMessage(BaseModel):
    id: UUID
    owner_id: int
    data: TaskCreate


@lru_cache
def sqs_client(long_poll: bool = False):
    return boto3.client(
        "sqs",
        config=Config(connect_timeout=2, read_timeout=25 if long_poll else 3, retries={"total_max_attempts": 2}),
    )
