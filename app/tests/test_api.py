import os
import uuid

os.environ.setdefault("JWT_SECRET", "test-secret-only-for-tests-0123456789abcdef")

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture
def token(client):
    username = f"user_{uuid.uuid4().hex[:8]}"
    r = client.post(
        "/auth/register", json={"username": username, "password": "password123"}
    )
    assert r.status_code == 201
    r = client.post(
        "/auth/login", data={"username": username, "password": "password123"}
    )
    assert r.status_code == 200
    return r.json()["access_token"]


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["database"] == "ok"


def test_docs_available(client):
    assert client.get("/docs").status_code == 200
    assert "/tasks" in client.get("/openapi.json").json()["paths"]


def test_protected_endpoints_return_401_without_token(client):
    assert client.get("/tasks").status_code == 401
    assert client.post("/tasks", json={"title": "x"}).status_code == 401
    assert client.get("/auth/me").status_code == 401
    assert (
        client.get("/tasks", headers={"Authorization": "Bearer garbage"}).status_code
        == 401
    )


def test_wrong_password(client, token):
    r = client.post(
        "/auth/login", data={"username": "nobody_here", "password": "wrongpass1"}
    )
    assert r.status_code == 401


def test_task_crud(client, token):
    h = {"Authorization": f"Bearer {token}"}
    r = client.post(
        "/tasks", json={"title": "Здати лабу", "description": "AWS"}, headers=h
    )
    assert r.status_code == 201
    task_id = r.json()["id"]

    assert [t["id"] for t in client.get("/tasks", headers=h).json()] == [task_id]

    r = client.patch(f"/tasks/{task_id}", json={"done": True}, headers=h)
    assert r.status_code == 200 and r.json()["done"] is True

    assert client.delete(f"/tasks/{task_id}", headers=h).status_code == 204
    assert client.get(f"/tasks/{task_id}", headers=h).status_code == 404


def test_users_cannot_see_each_others_tasks(client, token):
    other = client.post(
        "/auth/register",
        json={"username": f"o_{uuid.uuid4().hex[:8]}", "password": "password123"},
    )
    other_login = client.post(
        "/auth/login",
        data={"username": other.json()["username"], "password": "password123"},
    )
    h_other = {"Authorization": f"Bearer {other_login.json()['access_token']}"}

    task_id = client.post(
        "/tasks", json={"title": "secret"}, headers={"Authorization": f"Bearer {token}"}
    ).json()["id"]
    assert client.get(f"/tasks/{task_id}", headers=h_other).status_code == 404
