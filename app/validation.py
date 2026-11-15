"""Перевірка і нормалізація даних задачі (чисті функції без БД, покриті модульними тестами)."""

MAX_TITLE = 120
PRIORITIES = range(1, 6)


class ValidationError(ValueError):
    """Неправильні дані задачі."""


def normalize_title(raw):
    """Прибирає зайві пробіли; порожня або задовга назва є помилкою."""
    if not isinstance(raw, str):
        raise ValidationError("title must be a string")
    title = " ".join(raw.split())
    if not title:
        raise ValidationError("title must not be empty")
    if len(title) > MAX_TITLE:
        raise ValidationError(f"title is longer than {MAX_TITLE} characters")
    return title


def check_priority(value):
    """Пріоритет від 1 (найвищий) до 5; за замовчуванням 3."""
    if value is None:
        return 3
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError("priority must be an integer")
    if value not in PRIORITIES:
        raise ValidationError("priority must be between 1 and 5")
    return value


def task_summary(tasks):
    """Підсумок списку задач: усього, виконано, відкрито, відкриті за пріоритетом."""
    done = sum(1 for t in tasks if t["done"])
    by_priority = {}
    for t in tasks:
        if not t["done"]:
            key = str(t["priority"])
            by_priority[key] = by_priority.get(key, 0) + 1
    return {
        "total": len(tasks),
        "done": done,
        "open": len(tasks) - done,
        "open_by_priority": dict(sorted(by_priority.items())),
    }
