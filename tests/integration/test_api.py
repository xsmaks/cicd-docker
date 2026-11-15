"""Інтеграційні тести працюючого API (з реальними PostgreSQL і Redis). Адреса API у BASE_URL."""
import os
import uuid

import httpx
import pytest

BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")


@pytest.fixture(scope="module")
def client():
    with httpx.Client(base_url=BASE_URL, timeout=5) as c:
        yield c


def test_health_reports_version_and_commit(client):
    body = client.get("/health").json()
    assert body["status"] == "UP"
    assert body["commit"]


def test_dependencies_are_ready(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.json() == {"status": "READY", "database": "ok", "cache": "ok"}


def test_created_task_is_stored_in_database(client):
    title = f"CI task {uuid.uuid4().hex[:8]}"
    created = client.post("/tasks", json={"title": f"  {title}  ", "priority": 1})
    assert created.status_code == 201
    assert created.json()["title"] == title
    titles = [t["title"] for t in client.get("/tasks").json()]
    assert title in titles


def test_task_list_is_cached_in_redis(client):
    client.post("/tasks", json={"title": "cache warm-up"})   # скидає кеш
    first = client.get("/tasks")
    second = client.get("/tasks")
    assert first.headers["X-Cache"] == "MISS"
    assert second.headers["X-Cache"] == "HIT"
    assert first.json() == second.json()


def test_invalid_task_is_rejected(client):
    resp = client.post("/tasks", json={"title": "   ", "priority": 9})
    assert resp.status_code == 422


def test_complete_task_and_stats(client):
    task = client.post("/tasks", json={"title": "finish lab", "priority": 2}).json()
    done = client.patch(f"/tasks/{task['id']}/done")
    assert done.status_code == 200 and done.json()["done"] is True
    stats = client.get("/stats").json()
    assert stats["done"] >= 1
    assert stats["total"] == stats["done"] + stats["open"]


def test_unknown_task_returns_404(client):
    assert client.patch("/tasks/999999/done").status_code == 404


@pytest.mark.skipif(not os.getenv("EXPECT_PROXY"), reason="API викликається напряму, без nginx")
def test_requests_go_through_reverse_proxy(client):
    resp = client.get("/health")
    assert resp.headers.get("X-Proxy") == "taskboard-nginx"
