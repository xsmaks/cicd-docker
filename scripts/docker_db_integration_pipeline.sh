#!/usr/bin/env bash
# Файл: scripts/docker_db_integration_pipeline.sh
# Інтеграційний конвеєр Task Board на «голому» Docker CLI: ізольована мережа, PostgreSQL і Redis у фоні,
# опитування готовності, міграція схеми, запуск API та інтеграційні тести в одноразових контейнерах.
set -euo pipefail

PROJECT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
GIT_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD)"
RUN_ID="ci_${GIT_COMMIT}_${RANDOM}"
NETWORK_NAME="net_${RUN_ID}"
DB_CONTAINER="pg_${RUN_ID}"
REDIS_CONTAINER="redis_${RUN_ID}"
APP_CONTAINER="api_${RUN_ID}"
PG_IMAGE="postgres:16-alpine"
REDIS_IMAGE="redis:7-alpine"
PY_IMAGE="python:3.12-slim"
PIP_CACHE_VOLUME="taskboard-pip-cache"
APP_PORT="${APP_PORT:-18000}"                    # порт API на хості (лише 127.0.0.1)
DB_USER="tasks"
DB_PASS="ci_secret_pass"
DB_NAME="tasks_test_db"
MAX_RETRIES=30
ARTIFACTS_DIR="${PROJECT_DIR}/build_artifacts"

cleanup() {
    local exit_code=$?
    echo ""
    if [ "${exit_code}" -ne 0 ]; then
        echo "[ERROR] Конвеєр упав (код ${exit_code}). Останні рядки журналу API:"
        docker logs --tail 20 "${APP_CONTAINER}" 2>&1 || true
    fi
    echo "[CLEANUP] Зупинка та видалення тимчасових ресурсів Docker (${RUN_ID})..."
    docker rm -f "${APP_CONTAINER}" "${DB_CONTAINER}" "${REDIS_CONTAINER}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
    echo "[CLEANUP] Оточення очищено."
}
trap cleanup EXIT

# wait_for <назва> <команда...>: повторює команду щосекунди, доки вона не завершиться успішно
wait_for() {
    local name="$1"; shift
    local attempt=1
    until "$@" >/dev/null 2>&1; do
        if [ "${attempt}" -ge "${MAX_RETRIES}" ]; then
            echo "[ERROR] ${name}: перевищено ліміт очікування (${MAX_RETRIES} с)"
            return 1
        fi
        printf "  %s: спроба %d/%d, ще не готовий...\n" "${name}" "${attempt}" "${MAX_RETRIES}"
        sleep 1
        attempt=$((attempt + 1))
    done
    echo "[OK] ${name} готовий (спроба ${attempt})"
}

mkdir -p "${ARTIFACTS_DIR}"
echo "[STEP 1] Створення ізольованої мережі ${NETWORK_NAME}..."
docker network create "${NETWORK_NAME}" >/dev/null

echo "[STEP 2] Запуск PostgreSQL і Redis у фоновому режимі (-d)..."
docker run -d --name "${DB_CONTAINER}" --network "${NETWORK_NAME}" --network-alias postgres-db \
    -e POSTGRES_USER="${DB_USER}" -e POSTGRES_PASSWORD="${DB_PASS}" -e POSTGRES_DB="${DB_NAME}" \
    --tmpfs /var/lib/postgresql/data:rw,size=256m \
    "${PG_IMAGE}" >/dev/null
docker run -d --name "${REDIS_CONTAINER}" --network "${NETWORK_NAME}" --network-alias redis-cache \
    --memory 128m "${REDIS_IMAGE}" redis-server --save "" --appendonly no >/dev/null

echo "[STEP 3] Очікування готовності СУБД і кешу..."
wait_for "PostgreSQL" docker exec "${DB_CONTAINER}" pg_isready -U "${DB_USER}" -d "${DB_NAME}"
wait_for "Redis" docker exec "${REDIS_CONTAINER}" redis-cli ping

echo "[STEP 4] Міграція схеми в одноразовому контейнері psql..."
docker run --rm --network "${NETWORK_NAME}" \
    -v "${PROJECT_DIR}/migrations:/migrations:ro" \
    -e PGPASSWORD="${DB_PASS}" \
    "${PG_IMAGE}" \
    psql -h postgres-db -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q \
         -f /migrations/001_create_tasks.sql -c "\dt"

echo "[STEP 5] Запуск API Task Board (код примонтовано лише для читання)..."
docker run -d --name "${APP_CONTAINER}" --network "${NETWORK_NAME}" --network-alias app-api \
    -p "127.0.0.1:${APP_PORT}:8000" \
    -v "${PROJECT_DIR}:/app:ro" \
    -v "${PIP_CACHE_VOLUME}:/root/.cache/pip" \
    -w /app \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -e DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@postgres-db:5432/${DB_NAME}" \
    -e REDIS_URL="redis://redis-cache:6379/0" \
    -e APP_VERSION="1.0.0" -e GIT_COMMIT="${GIT_COMMIT}" \
    "${PY_IMAGE}" \
    sh -c 'pip install --quiet --disable-pip-version-check --root-user-action=ignore -r requirements.txt \
           && exec uvicorn app.main:app --host 0.0.0.0 --port 8000' >/dev/null
MAX_RETRIES=90 wait_for "API /ready" curl -fsS "http://127.0.0.1:${APP_PORT}/ready"
echo "  GET /health з хоста: $(curl -fsS "http://127.0.0.1:${APP_PORT}/health")"

echo "[STEP 6] Інтеграційні тести в одноразовому контейнері тієї ж мережі..."
docker run --rm --network "${NETWORK_NAME}" \
    -u "$(id -u):$(id -g)" \
    -v "${PROJECT_DIR}:/app" \
    -v "${PIP_CACHE_VOLUME}:/tmp/.cache/pip" \
    -w /app \
    -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 \
    -e BASE_URL="http://app-api:8000" \
    "${PY_IMAGE}" \
    sh -c 'pip install --user --quiet --disable-pip-version-check --no-warn-script-location \
             --root-user-action=ignore -r requirements-dev.txt \
           && /tmp/.local/bin/pytest -q -p no:cacheprovider tests/integration \
              --junitxml=build_artifacts/junit-integration.xml'

echo "[STEP 7] Дані, які тести залишили в БД:"
docker exec "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" \
    -c "SELECT id, title, priority, done FROM tasks ORDER BY id;"
echo "[SUCCESS] Інтеграційний сценарій для коміту ${GIT_COMMIT} успішно пройдено!"
