# syntax=docker/dockerfile:1
# Task Board API: багатоетапна збірка builder -> tester -> production

ARG PYTHON_IMAGE=python:3.12.16-slim-trixie

# ------------------------------------------------------------------------------
# Етап 1 (builder): ізольоване віртуальне оточення /opt/venv з runtime-залежностями
# ------------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore
WORKDIR /build
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# спочатку лише маніфест залежностей: зміна коду не скидає кеш цього шару
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# ------------------------------------------------------------------------------
# Етап 2 (tester): лінтер і модульні тести під час збірки; образ потім запускає інтеграційні тести
# ------------------------------------------------------------------------------
FROM builder AS tester
WORKDIR /app
COPY requirements-dev.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements-dev.txt
COPY pyproject.toml .
COPY app ./app
COPY tests ./tests
RUN ruff check --no-cache app tests \
    && pytest -q -p no:cacheprovider tests/unit
CMD ["pytest", "-q", "-p", "no:cacheprovider", "tests/integration"]

# ------------------------------------------------------------------------------
# Етап 3 (production): мінімальний образ без pip-кешу, тестів і dev-залежностей, від UID 10001
# ------------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS production
ARG APP_VERSION="0.0.0-dev"
ARG GIT_COMMIT="unknown"
ARG BUILD_DATE="unknown"
LABEL org.opencontainers.image.title="Task Board API" \
      org.opencontainers.image.description="FastAPI service with PostgreSQL storage and Redis cache" \
      org.opencontainers.image.source="https://github.com/xsmaks/cicd-docker" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_VERSION="${APP_VERSION}" \
    GIT_COMMIT="${GIT_COMMIT}"
WORKDIR /app
RUN groupadd -g 10001 appgroup \
    && useradd -u 10001 -g appgroup -s /usr/sbin/nologin -M appuser
COPY --from=builder --chown=appuser:appgroup /opt/venv /opt/venv
COPY --chown=appuser:appgroup app ./app
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
ENTRYPOINT ["uvicorn", "app.main:app"]
CMD ["--host", "0.0.0.0", "--port", "8000"]
