# Task Board API

Невеликий REST API задач для лабораторних робіт з контейнеризації (CI/CD інструментарій, 3ПРс,
Ревенко М. Ю.): FastAPI, PostgreSQL 16 і Redis 7.

| Метод | Шлях | Що робить |
|-------|------|-----------|
| GET | `/health` | процес живий, версія і коміт збірки |
| GET | `/ready` | доступні PostgreSQL і Redis |
| GET | `/tasks` | список задач (кешується в Redis, заголовок `X-Cache: HIT/MISS`) |
| POST | `/tasks` | нова задача `{"title": "...", "priority": 1..5}` |
| PATCH | `/tasks/{id}/done` | позначити задачу виконаною |
| GET | `/stats` | кількість задач: усього, виконано, відкрито за пріоритетом |

## Перевірка в контейнерах (робота №9)

На машині потрібні лише git, bash і Docker.

```bash
scripts/docker_ephemeral_test_runner.sh     # ruff + модульні тести в одноразовому python:3.12-slim
scripts/docker_db_integration_pipeline.sh   # PostgreSQL + Redis + API + інтеграційні тести
```

Результати (JUnit XML і JSON-звіт) з'являються в `build_artifacts/`.

## Образ Docker (робота №10)

`Dockerfile` має три іменовані етапи: `builder` (віртуальне оточення `/opt/venv`), `tester` (ruff і модульні
тести під час збірки) і `production` (python:3.12.16-slim-trixie, користувач 10001, HEALTHCHECK, запуск у
Exec-формі). `Dockerfile.naive` це навмисно наївний одноступеневий варіант для порівняння.

```bash
docker build --target production --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) \
    --build-arg APP_VERSION=$(cat VERSION) -t taskboard:$(cat VERSION) .
scripts/docker_build_benchmark.sh           # порівняння naive і multi-stage, перевірка образу
```

## Docker Compose (робота №11)

| Сервіс | Образ | Мережі | Роль |
|--------|-------|--------|------|
| reverse-proxy | nginx:1.27-alpine | frontend-net | зворотний проксі, єдиний вхід |
| app-api | taskboard (етап production) | frontend-net, backend-net | API |
| postgres-db | postgres:16-alpine | backend-net (internal) | БД |
| redis-cache | redis:7-alpine | backend-net (internal) | кеш списку задач |
| db-migrator | postgres:16-alpine | backend-net | одноразові SQL-міграції |
| integration-tests | taskboard-tester (етап tester), профіль `ci` | frontend-net | інтеграційні тести через nginx |

```bash
docker compose up -d --build                     # розробка: compose.yaml + compose.override.yaml, http://localhost:8088/docs
docker compose --profile debug up -d adminer     # Adminer: http://localhost:8089
scripts/docker_compose_ci_runner.sh              # CI: compose.yaml + compose.ci.yaml, профіль ci
```
