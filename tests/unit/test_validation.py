import pytest

from app.validation import MAX_TITLE, ValidationError, check_priority, normalize_title, task_summary


def test_title_spaces_are_collapsed():
    assert normalize_title("  Купити   молоко ") == "Купити молоко"


@pytest.mark.parametrize("bad", ["", "   ", None, 42])
def test_empty_or_wrong_title_is_rejected(bad):
    with pytest.raises(ValidationError):
        normalize_title(bad)


def test_too_long_title_is_rejected():
    with pytest.raises(ValidationError):
        normalize_title("x" * (MAX_TITLE + 1))


def test_default_priority_is_three():
    assert check_priority(None) == 3


@pytest.mark.parametrize("value", [1, 3, 5])
def test_valid_priorities(value):
    assert check_priority(value) == value


@pytest.mark.parametrize("value", [0, 6, -1, "2", 2.5, True])
def test_invalid_priorities(value):
    with pytest.raises(ValidationError):
        check_priority(value)


def test_task_summary_counts_open_tasks_by_priority():
    tasks = [
        {"priority": 1, "done": False},
        {"priority": 1, "done": True},
        {"priority": 3, "done": False},
        {"priority": 1, "done": False},
    ]
    assert task_summary(tasks) == {
        "total": 4, "done": 1, "open": 3, "open_by_priority": {"1": 2, "3": 1},
    }


def test_task_summary_of_empty_list():
    assert task_summary([]) == {"total": 0, "done": 0, "open": 0, "open_by_priority": {}}
