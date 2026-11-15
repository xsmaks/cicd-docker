-- Схема Task Board: таблиця задач і журнал застосованих міграцій
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    VARCHAR(64) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tasks (
    id         SERIAL PRIMARY KEY,
    title      VARCHAR(120) NOT NULL,
    priority   SMALLINT NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    done       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO schema_migrations (version) VALUES ('001_create_tasks') ON CONFLICT DO NOTHING;
