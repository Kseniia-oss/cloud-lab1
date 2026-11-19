from concurrent.futures import ThreadPoolExecutor

from app import idempotency
from app.config import get_settings
from app.routers import task_jobs
from app.task_queue import TaskMessage
from app.worker import persist_task
from test_api import client, token


def test_idempotency_replays_same_result_across_concurrent_requests(client, token, monkeypatch):
    monkeypatch.setattr(get_settings(), "idempotency_redis_url", "redis://test")
    stored = {}

    class RedisDouble:
        def get(self, key):
            return stored.get(key)

        def set(self, key, value, *, px):
            assert 0 < px <= 86_400_000
            stored[key] = value

    monkeypatch.setattr(idempotency, "get_redis", lambda url: RedisDouble())
    auth = {"Authorization": f"Bearer {token}"}
    headers = {**auth, "Idempotency-Key": "lab2-retry"}
    payload = {"title": "Idempotent task"}
    with ThreadPoolExecutor(max_workers=2) as executor:
        requests = [
            executor.submit(client.post, "/tasks", json=payload, headers=headers)
            for _ in range(2)
        ]
    first, second = [request.result() for request in requests]
    assert first.status_code == second.status_code == 201
    assert first.content == second.content
    assert stored
    assert client.get("/tasks", headers=auth).json() == [first.json()]
    changed = client.post("/tasks", json={"title": "Changed"}, headers=headers)
    assert changed.status_code == 409


def test_job_status_and_worker_redelivery(client, token, monkeypatch):
    monkeypatch.setattr(get_settings(), "tasks_queue_url", "https://queue.test/jobs")
    messages = []

    class QueueDouble:
        def send_message(self, *, QueueUrl, MessageBody):
            messages.append(TaskMessage.model_validate_json(MessageBody))

    monkeypatch.setattr(task_jobs, "sqs_client", QueueDouble)
    auth = {"Authorization": f"Bearer {token}"}
    submitted = client.post("/task-jobs", json={"title": "Queued task"}, headers=auth)
    assert submitted.status_code == 202
    location = submitted.headers["Location"]
    headers = {**auth, "X-Job-Ticket": submitted.json()["ticket"]}
    assert client.get(location, headers=headers).json()["status"] == "pending"
    persist_task(messages[0])
    persist_task(messages[0])
    result = client.get(location, headers=headers).json()
    assert result["status"] == "completed"
    assert client.get("/tasks", headers=auth).json() == [result["task"]]
