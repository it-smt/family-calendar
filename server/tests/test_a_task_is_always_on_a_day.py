"""The day list finds a task by its date, so a task without one is invisible.

`TaskRepository.tasksOnDay` asks for the rows whose `starts_at` falls inside the
day. The editor used to allow a task with no date at all — neither a time nor
"all day" — and such a row was written to the database successfully and then
shown by no screen in the app: not that day, not any other day, not the widget.
Nothing reported it, because nothing had failed.

The editor no longer offers that state: every task has a day, and "all day"
means midnight on it rather than no time at all. These tests are the day
window, transcribed, held against rows written the way the app writes them.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from tests.device import CLIENT_ROOT, Device, wire_time
from tests.test_first_run_works_offline import register_without_syncing
from tests.test_offline_convergence import PASSWORD, enrol


def repair(device: Device) -> None:
    """The v6 migration, run the way `DatabaseMigrator` runs it."""
    device.db.executescript(
        (CLIENT_ROOT / "SQL/v6_date_the_dateless_tasks.sql").read_text()
    )


def day_window(day: datetime) -> tuple[str, str]:
    """`tasksOnDay`: from the start of the day to the start of the next."""
    start = day.replace(hour=0, minute=0, second=0, microsecond=0)
    return wire_time(start), wire_time(start + timedelta(days=1))


def tasks_on_day(device: Device, day: datetime) -> list[str]:
    """`TaskRepository.tasksTouching`, transcribed.

    Not "tasks whose `starts_at` is today" any more: a repeating task is stored
    once, on the day it started, and the instants it falls on afterwards are
    worked out on the device. So the query also takes every rule that began
    before the day ends, and the expansion happens above it.
    """
    start, end = day_window(day)
    rows = device.db.execute(
        "SELECT title, rrule FROM tasks "
        "WHERE deleted_at IS NULL "
        "  AND ((starts_at >= ? AND starts_at < ?) OR (rrule IS NOT NULL AND starts_at < ?)) "
        "ORDER BY starts_at",
        (start, end, end),
    )
    return [row["title"] for row in rows]


async def test_a_task_with_a_time_is_on_its_day(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    day = datetime(2026, 9, 20, tzinfo=UTC)
    device.create_task("Врач", starts_at=wire_time(day.replace(hour=16)))

    assert tasks_on_day(device, day) == ["Врач"]
    assert tasks_on_day(device, day + timedelta(days=1)) == []


async def test_an_all_day_task_sits_at_midnight_and_is_found(api):
    """How the editor now saves "весь день": the start of the day, not nothing."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    day = datetime(2026, 9, 20, tzinfo=UTC)
    device.create_task("Дача", starts_at=wire_time(day), is_all_day=1)

    assert tasks_on_day(device, day) == ["Дача"]


async def test_an_all_day_task_sorts_above_the_timed_ones(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    day = datetime(2026, 9, 20, tzinfo=UTC)
    device.create_task("Врач", starts_at=wire_time(day.replace(hour=16)))
    device.create_task("Дача", starts_at=wire_time(day), is_all_day=1)

    assert tasks_on_day(device, day) == ["Дача", "Врач"]


async def test_a_task_with_no_date_is_on_no_day_at_all(api):
    """Why the editor cannot make one any more, stated as a test."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    device.create_task("Ни на каком дне")

    days = [datetime(2026, 9, 18, tzinfo=UTC) + timedelta(days=n) for n in range(-400, 400)]
    assert all(tasks_on_day(device, day) == [] for day in days)


async def test_the_repair_puts_an_old_dateless_task_on_a_day(api):
    """v6, against a row written the way the broken build wrote them."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    created = datetime(2026, 9, 18, 11, 30, tzinfo=UTC)
    device.create_task("Из старой сборки", created_at=wire_time(created))
    assert tasks_on_day(device, created) == []

    repair(device)

    assert tasks_on_day(device, created) == ["Из старой сборки"]
    row = device.db.execute("SELECT * FROM tasks").fetchone()
    assert row["is_all_day"] == 1
    assert row["dirty"] == 1


async def test_the_repair_reaches_the_other_phone(api):
    """It is marked dirty, so the correction is pushed like any other edit."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    created = datetime(2026, 9, 18, 11, 30, tzinfo=UTC)
    task_id = device.create_task("Из старой сборки", created_at=wire_time(created))
    repair(device)

    await device.sync()

    invite = (
        await api.post(
            "/auth/login",
            json={"email": "alice@example.com", "password": PASSWORD},
        )
    ).json()["invite_code"]
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=invite)

    assert bob.task(task_id)["starts_at"] == "2026-09-18T00:00:00.000Z"
    assert bob.task(task_id)["is_all_day"] in (1, True)


@pytest.mark.parametrize("hour", [0, 11, 23])
async def test_the_repair_leaves_a_dated_task_alone(api, hour: int):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    when = wire_time(datetime(2026, 9, 20, hour, tzinfo=UTC))
    device.create_task("Врач", starts_at=when)

    repair(device)

    row = device.db.execute("SELECT * FROM tasks").fetchone()
    assert row["starts_at"] == when
    assert row["is_all_day"] == 0


# --- what the day card counts -------------------------------------------------


def add_subtask(device: Device, task_id: str, title: str, *, done: int = 0,
                deleted: bool = False) -> str:
    subtask_id = str(uuid.uuid4()).upper()
    moment = device.now()
    device.db.execute(
        "INSERT INTO subtasks "
        "(id, household_id, task_id, title, is_done, sort_order, created_at, "
        " updated_at, updated_by, deleted_at, dirty) "
        "VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 1)",
        (
            subtask_id,
            device.household_id,
            task_id,
            title,
            done,
            moment,
            moment,
            device.user_id,
            moment if deleted else None,
        ),
    )
    device.db.commit()
    return subtask_id


def packing(device: Device) -> dict[str, tuple[int, int]]:
    """`SubtaskRepository.observeProgress`, transcribed."""
    rows = device.db.execute(
        "SELECT task_id AS task, COUNT(*) AS total, SUM(is_done) AS done "
        "FROM subtasks WHERE deleted_at IS NULL GROUP BY task_id"
    )
    return {row["task"]: (row["done"], row["total"]) for row in rows}


async def test_the_day_card_counts_what_is_packed(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    task = device.create_task("Бассейн", starts_at=device.now())
    add_subtask(device, task, "Шапочка", done=1)
    add_subtask(device, task, "Очки")
    add_subtask(device, task, "Полотенце")

    assert packing(device)[task] == (1, 3)


async def test_a_deleted_item_leaves_the_count(api):
    """Tombstones stay in the table; they are not part of the list any more."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    task = device.create_task("Бассейн", starts_at=device.now())
    add_subtask(device, task, "Шапочка", done=1)
    add_subtask(device, task, "Очки", deleted=True)

    assert packing(device)[task] == (1, 1)


async def test_a_task_with_no_list_is_not_counted_at_all(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    device.create_task("Врач", starts_at=device.now())

    assert packing(device) == {}


# --- repeats ------------------------------------------------------------------


async def test_a_repeating_task_is_a_candidate_for_a_later_day(api):
    """The row stays on the day it started; the day query still has to see it."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    start = datetime(2026, 9, 1, 9, tzinfo=UTC)
    device.create_task("Вынести мусор", starts_at=wire_time(start), rrule="FREQ=WEEKLY")

    assert tasks_on_day(device, start) == ["Вынести мусор"]
    assert tasks_on_day(device, start + timedelta(days=7)) == ["Вынести мусор"]
    assert tasks_on_day(device, start + timedelta(days=70)) == ["Вынести мусор"]


async def test_a_repeating_task_is_not_a_candidate_before_it_starts(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    start = datetime(2026, 9, 10, 9, tzinfo=UTC)
    device.create_task("Вынести мусор", starts_at=wire_time(start), rrule="FREQ=WEEKLY")

    assert tasks_on_day(device, start - timedelta(days=1)) == []


async def test_a_one_off_task_is_still_only_on_its_own_day(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    day = datetime(2026, 9, 20, tzinfo=UTC)
    device.create_task("Врач", starts_at=wire_time(day.replace(hour=16)))

    assert tasks_on_day(device, day) == ["Врач"]
    assert tasks_on_day(device, day + timedelta(days=7)) == []
