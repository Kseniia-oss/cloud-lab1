import logging
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID, uuid4

import jwt
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Header, HTTPException, Response, status

from app.config import get_settings
from app.models import TaskQueueReceipt
from app.schemas import TaskCreate, TaskOut
from app.security import CurrentUser, DbSession
from app.task_queue import TaskMessage, sqs_client

router = APIRouter(prefix="/task-jobs", tags=["task jobs"])
log = logging.getLogger(__name__)
AUDIENCE = "tasks-api:job-status"


@router.post("", status_code=status.HTTP_202_ACCEPTED)
def submit_job(data: TaskCreate, user: CurrentUser, response: Response):
    settings = get_settings()
    if not settings.tasks_queue_url:
        raise HTTPException(503, "Task queue is disabled")

    message = TaskMessage(id=uuid4(), owner_id=user.id, data=data)
    try:
        sqs_client().send_message(
            QueueUrl=settings.tasks_queue_url, MessageBody=message.model_dump_json()
        )
    except (BotoCoreError, ClientError):
        log.exception("Unable to enqueue task")
        raise HTTPException(503, "Task queue is unavailable")

    ticket = jwt.encode(
        {
            "aud": AUDIENCE,
            "sub": str(user.id),
            "job": str(message.id),
            "exp": datetime.now(UTC) + timedelta(days=1),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    location = f"/task-jobs/{message.id}"
    response.headers["Location"] = location
    response.headers["Cache-Control"] = "private, no-store"
    return {"id": message.id, "status": "pending", "status_url": location, "ticket": ticket}


@router.get("/{job_id}")
def job_status(
    job_id: UUID, user: CurrentUser, db: DbSession, response: Response,
    ticket: Annotated[str, Header(alias="X-Job-Ticket")],
):
    settings = get_settings()
    try:
        claims = jwt.decode(
            ticket, settings.jwt_secret, algorithms=[settings.jwt_algorithm],
            audience=AUDIENCE, options={"require": ["exp", "sub", "job"]},
        )
    except jwt.InvalidTokenError:
        raise HTTPException(404, "Job not found")
    if claims["job"] != str(job_id) or claims["sub"] != str(user.id):
        raise HTTPException(404, "Job not found")

    response.headers["Cache-Control"] = "private, no-store"
    receipt = db.get(TaskQueueReceipt, job_id)
    if receipt is None:
        return {"id": job_id, "status": "pending"}
    if receipt.owner_id != user.id:
        raise HTTPException(404, "Job not found")
    return {"id": job_id, "status": "completed", "task": TaskOut.model_validate(receipt.result)}
