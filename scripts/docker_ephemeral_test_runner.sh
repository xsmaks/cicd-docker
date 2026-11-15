#!/usr/bin/env bash
# Файл: scripts/docker_ephemeral_test_runner.sh
# Одноразовий контейнер python:3.12-slim перевіряє код Task Board: лінтер ruff і модульні тести pytest.
# На хості потрібні лише git, bash і Docker; результат (JUnit XML і JSON-звіт) лишається в build_artifacts.
set -euo pipefail

PROJECT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
IMAGE_NAME="${IMAGE_NAME:-python:3.12-slim}"
ARTIFACTS_DIR="${PROJECT_DIR}/build_artifacts"
PIP_CACHE_VOLUME="taskboard-pip-cache"          # іменований том: кеш pip між запусками
GIT_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD)"
GIT_BRANCH="$(git -C "${PROJECT_DIR}" rev-parse --abbrev-ref HEAD)"

mkdir -p "${ARTIFACTS_DIR}"
rm -f "${ARTIFACTS_DIR}"/unit_report.json "${ARTIFACTS_DIR}"/junit-unit.xml

echo "[INFO] Проєкт: ${PROJECT_DIR} (гілка ${GIT_BRANCH}, коміт ${GIT_COMMIT})"
echo "[INFO] Запуск ізольованого середовища перевірки на базі ${IMAGE_NAME}..."

set +e
docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "${PROJECT_DIR}:/app" \
    -v "${PIP_CACHE_VOLUME}:/tmp/.cache/pip" \
    -w /app \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -e HOME=/tmp \
    -e GIT_COMMIT="${GIT_COMMIT}" \
    -e GIT_BRANCH="${GIT_BRANCH}" \
    "${IMAGE_NAME}" \
    sh -c '
        set -e
        echo "--- [Container] Середовище: $(python3 --version), ядро $(uname -r), uid $(id -u)"
        echo "--- [Container] Встановлення залежностей у /tmp/.local (кеш pip у томі) ---"
        pip install --user --quiet --disable-pip-version-check --no-warn-script-location \
            --root-user-action=ignore -r requirements.txt -r requirements-dev.txt
        export PATH="/tmp/.local/bin:${PATH}"
        echo "--- [Container] Статичний аналіз коду (ruff) ---"
        ruff check --no-cache app tests
        echo "--- [Container] Модульні тести (pytest tests/unit) ---"
        pytest -q -p no:cacheprovider tests/unit --junitxml=build_artifacts/junit-unit.xml
        echo "--- [Container] Генерація звіту збірки ---"
        python3 - <<PY
import datetime, json, pathlib, platform, xml.etree.ElementTree as ET, os
suite = ET.parse("build_artifacts/junit-unit.xml").getroot().find("testsuite")
report = {
    "status": "SUCCESS",
    "project": "task-board",
    "commit": os.environ["GIT_COMMIT"],
    "branch": os.environ["GIT_BRANCH"],
    "python_version": platform.python_version(),
    "kernel": platform.release(),
    "tests": int(suite.get("tests")),
    "failures": int(suite.get("failures")) + int(suite.get("errors")),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
}
pathlib.Path("build_artifacts/unit_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
PY
    '
rc=$?
set -e

if [ "${rc}" -ne 0 ]; then
    echo "[FAIL] Перевірка не пройшла (код ${rc}): контейнер уже видалено, звіт не створено."
    exit "${rc}"
fi
echo "[SUCCESS] Перевірку завершено. Артефакти на хості:"
ls -l "${ARTIFACTS_DIR}"
cat "${ARTIFACTS_DIR}/unit_report.json"
