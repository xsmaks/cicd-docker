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
