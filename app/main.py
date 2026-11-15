"""HTTP API: задачі зберігаються в PostgreSQL, список кешується в Redis."""
import json
import os
import socket

import psycopg
import redis
from fastapi import FastAPI, HTTPException, Response
from psycopg.rows import dict_row
from pydantic import BaseModel

from app.validation import ValidationError, check_priority, normalize_title, task_summary

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://tasks:tasks@localhost:5432/tasks")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
CACHE_KEY = "tasks:all"
CACHE_TTL = int(os.getenv("CACHE_TTL", "30"))

app = FastAPI(title="Task Board API", version=os.getenv("APP_VERSION", "dev"))
cache = redis.Redis.from_url(REDIS_URL, decode_responses=True, socket_timeout=2)


class TaskIn(BaseModel):
    title: str
    priority: int | None = None


def db():
    return psycopg.connect(DATABASE_URL, row_factory=dict_row, connect_timeout=3)


def row_to_task(row):
    return {"id": row["id"], "title": row["title"], "priority": row["priority"],
            "done": row["done"], "created_at": row["created_at"].isoformat()}


@app.get("/health")
def health():
    """Liveness: процес живий і відповідає; залежності не перевіряє."""
    return {"status": "UP", "version": os.getenv("APP_VERSION", "dev"),
            "commit": os.getenv("GIT_COMMIT", "unknown"), "host": socket.gethostname(),
            "uid": os.getuid()}


@app.get("/ready")
def ready():
    """Readiness: доступні PostgreSQL і Redis."""
    try:
        with db() as conn:
            conn.execute("SELECT 1")
        cache.ping()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"dependency is not ready: {exc}") from exc
    return {"status": "READY", "database": "ok", "cache": "ok"}


@app.get("/tasks")
def list_tasks(response: Response):
    cached = cache.get(CACHE_KEY)
    if cached is not None:
        response.headers["X-Cache"] = "HIT"
        return json.loads(cached)
    with db() as conn:
        rows = conn.execute("SELECT * FROM tasks ORDER BY done, priority, id").fetchall()
    tasks = [row_to_task(r) for r in rows]
    cache.setex(CACHE_KEY, CACHE_TTL, json.dumps(tasks))
    response.headers["X-Cache"] = "MISS"
    return tasks


@app.post("/tasks", status_code=201)
def create_task(task: TaskIn):
    try:
        title = normalize_title(task.title)
        priority = check_priority(task.priority)
    except ValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    with db() as conn:
        row = conn.execute("INSERT INTO tasks (title, priority) VALUES (%s, %s) RETURNING *",
                           (title, priority)).fetchone()
    cache.delete(CACHE_KEY)
    return row_to_task(row)


@app.patch("/tasks/{task_id}/done")
def complete_task(task_id: int):
    with db() as conn:
        row = conn.execute("UPDATE tasks SET done = TRUE WHERE id = %s RETURNING *", (task_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="task not found")
    cache.delete(CACHE_KEY)
    return row_to_task(row)


@app.get("/stats")
def stats():
    with db() as conn:
        rows = conn.execute("SELECT priority, done FROM tasks").fetchall()
    return task_summary(rows)
