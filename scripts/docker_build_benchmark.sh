#!/usr/bin/env bash
# Файл: scripts/docker_build_benchmark.sh
# Бенчмарк пакування Task Board в OCI-образ: наївний одноступеневий Dockerfile.naive проти багатоетапного
# Dockerfile (builder -> tester -> production). Контекст збірки береться з Git-репозиторію проєкту,
# метадані коміту передаються через --build-arg. Журнали збірок лишаються в build_artifacts/.
set -euo pipefail

PROJECT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "${PROJECT_DIR}"
ARTIFACTS_DIR="${PROJECT_DIR}/build_artifacts"
IMAGE="taskboard"
GIT_COMMIT="$(git rev-parse --short HEAD)"
APP_VERSION="$(cat VERSION)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NAIVE_TAG="${IMAGE}:naive"
TESTER_TAG="${IMAGE}:tester-${GIT_COMMIT}"
PROD_TAG="${IMAGE}:${APP_VERSION}-${GIT_COMMIT}"
CONTAINER="taskboard_bench_${RANDOM}"
APP_PORT="${APP_PORT:-18080}"
KEEP_IMAGES="${KEEP_IMAGES:-1}"     # 1: залишити образи для огляду (docker history) і для compose
export DOCKER_BUILDKIT=1

cleanup() {
    echo ""
    echo "[CLEANUP] Видалення тестового контейнера і проміжних образів..."
    docker rm -f -v "${CONTAINER}" >/dev/null 2>&1 || true
    if [ "${KEEP_IMAGES}" != 1 ]; then
        docker rmi -f "${NAIVE_TAG}" "${TESTER_TAG}" "${PROD_TAG}" >/dev/null 2>&1 || true
    fi
    echo "[CLEANUP] Завершено."
}
trap cleanup EXIT

# build <назва журналу> <аргументи docker build...>: збірка з журналом і заміром часу
build() {
    local log="${ARTIFACTS_DIR}/build-$1.log"; shift
    local start end
    start=$(date +%s.%N)
    if ! docker build --progress=plain "$@" . >"${log}" 2>&1; then
        echo "[FAIL] Збірка впала, останні рядки ${log}:"; tail -n 15 "${log}"; return 1
    fi
    end=$(date +%s.%N)
    LAST_TIME=$(printf '%.1f' "$(echo "${end} - ${start}" | bc)")
    LAST_CACHED=$(grep -c ' CACHED$' "${log}" || true)
}

# row <назва>: рядок таблиці часу збірок (колонки вирівнює column)
row() {
    echo "$1|${LAST_TIME}|${LAST_CACHED}" >> "${ARTIFACTS_DIR}/build-times.txt"
}

mkdir -p "${ARTIFACTS_DIR}"
echo "[INFO] Task Board ${APP_VERSION}, коміт ${GIT_COMMIT}, дата збірки ${BUILD_DATE}"
echo "Збірка|Час, с|Кроків з кешу" > "${ARTIFACTS_DIR}/build-times.txt"

echo "[STEP 0] Контекст збірки: що відкидає .dockerignore..."
echo "  каталог проєкту без фільтра: $(find . -type f | wc -l) файлів, $(du -sk . | cut -f1) КБ (разом із .git)"
printf 'FROM busybox:1.36\nCOPY . /ctx\nRUN echo "CTX $(find /ctx -type f | wc -l) $(du -sk /ctx | cut -f1)"\n' \
    | docker build --no-cache --progress=plain -f - . 2>&1 | grep -o 'CTX [0-9]* [0-9]*$' | tail -n1 \
    | awk '{print "  контекст з .dockerignore:    " $2 " файлів, " $3 " КБ"}'

echo "[STEP 1] Наївний образ ${NAIVE_TAG} (Dockerfile.naive, без кешу)..."
build naive -f Dockerfile.naive --no-cache -t "${NAIVE_TAG}"
row "naive (--no-cache)"

echo "[STEP 2] Етап tester: лінтер і модульні тести під час збірки (--target tester)..."
build tester --target tester --no-cache -t "${TESTER_TAG}"
row "tester (--no-cache)"
grep -E 'All checks passed|passed in' "${ARTIFACTS_DIR}/build-tester.log" | sed 's/^#[0-9]* [0-9.]* /  /'

echo "[STEP 3] Етап production з метаданими Git (--build-arg), холодна і повторна збірка..."
PROD_ARGS=(--target production
           --build-arg APP_VERSION="${APP_VERSION}"
           --build-arg GIT_COMMIT="${GIT_COMMIT}"
           --build-arg BUILD_DATE="${BUILD_DATE}"
           -t "${PROD_TAG}")
build production-cold --no-cache "${PROD_ARGS[@]}"
row "production (--no-cache)"
build production-warm "${PROD_ARGS[@]}"
row "production (повторно, з кешем)"
if grep -q '\[tester' "${ARTIFACTS_DIR}/build-production-cold.log"; then
    echo "  [WARN] під час збірки production виконувався етап tester"
else
    echo "  етап tester при збірці production пропущено (production від нього не залежить)"
fi
column -t -s "|" "${ARTIFACTS_DIR}/build-times.txt" | sed 's/^/  /'

echo ""
echo "[STEP 4] Порівняння розмірів образів:"
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" \
    | grep -E "REPOSITORY|^${IMAGE}:" | tee "${ARTIFACTS_DIR}/image-sizes.txt"

echo ""
echo "[STEP 5] Метадані production-образу:"
docker image inspect "${PROD_TAG}" --format '  User: {{.Config.User}}
  Entrypoint: {{json .Config.Entrypoint}}  Cmd: {{json .Config.Cmd}}
  Healthcheck: {{json .Config.Healthcheck.Test}}
  version={{index .Config.Labels "org.opencontainers.image.version"}} revision={{index .Config.Labels "org.opencontainers.image.revision"}}'
echo "  gcc у naive: $(docker run --rm "${NAIVE_TAG}" sh -c 'command -v gcc || echo немає'),"\
     "у production: $(docker run --rm --entrypoint sh "${PROD_TAG}" -c 'command -v gcc || echo немає')"
echo "  .git у naive: $(docker run --rm "${NAIVE_TAG}" sh -c 'test -d /app/.git && echo є || echo немає'),"\
     "у production: $(docker run --rm --entrypoint sh "${PROD_TAG}" -c 'test -d /app/.git && echo є || echo немає')"

echo ""
echo "[STEP 6] Запуск production-контейнера і самодіагностика HEALTHCHECK..."
docker run -d --name "${CONTAINER}" -p "127.0.0.1:${APP_PORT}:8000" "${PROD_TAG}" >/dev/null
for attempt in $(seq 1 30); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}")
    [ "${status}" = healthy ] && break
    sleep 1
done
echo "  стан контейнера після ${attempt} с: ${status}"
echo "  GET /health: $(curl -fsS "http://127.0.0.1:${APP_PORT}/health")"
echo "  процес PID 1: $(docker exec "${CONTAINER}" sh -c 'tr "\0" " " < /proc/1/cmdline')"
start=$(date +%s.%N)
docker stop "${CONTAINER}" >/dev/null
echo "  docker stop (SIGTERM для PID 1): $(printf '%.1f' "$(echo "$(date +%s.%N) - ${start}" | bc)") с," \
     "код виходу $(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")"
echo "[SUCCESS] Образ ${PROD_TAG} зібрано і перевірено."
