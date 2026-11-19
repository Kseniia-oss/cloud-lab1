import logging
from time import sleep

from sqlalchemy import text

from app.config import get_settings
from app.database import SessionLocal, init_db
from app.models import Task, TaskQueueReceipt
from app.schemas import TaskOut
from app.task_queue import TaskMessage, sqs_client

log = logging.getLogger(__name__)


def persist_task(message: TaskMessage) -> None:
    with SessionLocal.begin() as db:
        lock_id = int.from_bytes(message.id.bytes[:8], "big", signed=True)
        db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": lock_id})
        if db.get(TaskQueueReceipt, message.id) is not None:
            return
        task = Task(
            title=message.data.title,
            description=message.data.description,
            owner_id=message.owner_id,
        )
        db.add(task)
        db.flush()
        db.add(
            TaskQueueReceipt(
                id=message.id,
                owner_id=message.owner_id,
                result=TaskOut.model_validate(task).model_dump(mode="json"),
            )
        )


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    queue_url = get_settings().tasks_queue_url
    if not queue_url:
        raise RuntimeError("TASKS_QUEUE_URL is required")
    init_db()
    sqs = sqs_client(long_poll=True)
    while True:
        try:
            batch = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=20)
            for item in batch.get("Messages", []):
                persist_task(TaskMessage.model_validate_json(item["Body"]))
                sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=item["ReceiptHandle"])
        except Exception:
            log.exception("Queue processing failed; unacknowledged messages can be redelivered")
            sleep(2)


if __name__ == "__main__":
    main()
