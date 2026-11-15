#!/usr/bin/env bash
# Файл: scripts/docker_compose_ci_runner.sh
# CI-прогін Task Board у Docker Compose: валідація злиття compose.yaml + compose.ci.yaml, збірка образів
# з метаданими коміту, запуск графа сервісів, інтеграційні тести в контейнері integration-tests (профіль ci),
# посмертний збір журналів при збої та гарантоване знищення стеку.
set -euo pipefail

PROJECT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ARTIFACTS_DIR="${PROJECT_DIR}/build_artifacts"

export GIT_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD)"
export APP_VERSION="$(cat "${PROJECT_DIR}/VERSION")"
export BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
# унікальне ім'я проєкту: паралельні CI-джоби не чіпають ресурси одна одної
CI_PROJECT_NAME="ci_taskboard_${GIT_COMMIT}_${RANDOM}"

mkdir -p "${ARTIFACTS_DIR}"
rm -f "${ARTIFACTS_DIR}/junit-compose.xml"

COMPOSE_CMD=(
    docker compose
    -p "${CI_PROJECT_NAME}"
    --project-directory "${PROJECT_DIR}"
    -f "${PROJECT_DIR}/compose.yaml"
    -f "${PROJECT_DIR}/compose.ci.yaml"
    --profile ci
)

cleanup() {
    local exit_code=$?
    echo ""
    if [ "${exit_code}" -ne 0 ]; then
        echo "[ERROR] Конвеєр завершився з помилкою (код ${exit_code}). Журнали стеку:"
        "${COMPOSE_CMD[@]}" logs --no-color --tail=20 || true
    fi
    echo "[CLEANUP] Знищення ізольованого стеку Compose (${CI_PROJECT_NAME})..."
    "${COMPOSE_CMD[@]}" down --volumes --remove-orphans --timeout 5 >/dev/null 2>&1 || true
    echo "[CLEANUP] Контейнери, мережі і томи проєкту видалено:" \
         "$(docker ps -aq --filter "label=com.docker.compose.project=${CI_PROJECT_NAME}" | wc -l) контейнерів," \
         "$(docker network ls -q --filter "label=com.docker.compose.project=${CI_PROJECT_NAME}" | wc -l) мереж."
}
trap cleanup EXIT

echo "[INFO] Task Board ${APP_VERSION}, коміт ${GIT_COMMIT}, проєкт Compose ${CI_PROJECT_NAME}"
echo "[STEP 1] Валідація результуючого маніфесту (compose.yaml + compose.ci.yaml, профіль ci)..."
"${COMPOSE_CMD[@]}" config --quiet
echo "[OK] Синтаксис коректний; сервіси: $("${COMPOSE_CMD[@]}" config --services | sort | tr '\n' ' ')"
if "${COMPOSE_CMD[@]}" config | grep -q 'published:'; then
    echo "[ERROR] у CI-конфігурації опубліковано порти на хості"; exit 1
fi

echo "[STEP 2] Збірка образів app-api (production) та integration-tests (tester)..."
"${COMPOSE_CMD[@]}" build --quiet
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E "taskboard(-tester)?:.*${GIT_COMMIT}"

echo "[STEP 3] Запуск графа сервісів та інтеграційних тестів..."
"${COMPOSE_CMD[@]}" up \
    --abort-on-container-exit \
    --exit-code-from integration-tests \
    --attach integration-tests \
    --no-color --quiet-pull

echo ""
echo "[STEP 4] Підсумковий стан контейнерів:"
"${COMPOSE_CMD[@]}" ps -a --format 'table {{.Service}}\t{{.Status}}'
echo "[STEP 5] Артефакт тестування на хості:"
grep -o '<testsuite [^>]*' "${ARTIFACTS_DIR}/junit-compose.xml" | grep -oE '(tests|failures|errors|time)="[^"]*"' | tr '\n' ' '
echo ""
echo "[SUCCESS] Інтеграційний конвеєр Docker Compose для коміту ${GIT_COMMIT} успішно завершено!"
