"""Ticking off one instant of a repeat.

A repeating task is one row and a rule, so there is nowhere on it to record
that this Tuesday is done. It used to be struck out of the rule instead: the
line vanished rather than going grey, and "skipped" and "done" became the same
thing.

One row per completed instant, and deliberately no unique constraint on
(task_id, occurrence) — two phones ticking the same Tuesday while both are
offline each make a row, and a constraint the device can violate is worse than
a duplicate: the loser would retry a rejected push for ever. Any live row means
done.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from tests.device import Device, wire_time
from tests.test_first_run_works_offline import register_without_syncing
from tests.test_offline_convergence import PASSWORD, enrol

START = datetime(2026, 9, 21, 9, 0, tzinfo=UTC)


def tick(device: Device, task_id: str, occurrence: datetime) -> str:
    completion_id = str(uuid.uuid4()).upper()
    moment = device.now()
    device.db.execute(
        "INSERT INTO occurrence_completions "
        "(id, household_id, task_id, occurrence, completed_by, created_at, updated_at, "
        " updated_by, dirty) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)",
        (
            completion_id,
            device.household_id,
            task_id,
            wire_time(occurrence),
            device.user_id,
            moment,
            moment,
            device.user_id,
        ),
    )
    device.db.commit()
    return completion_id


def done(device: Device, task_id: str, occurrence: datetime) -> bool:
    """`DayViewModel`: any live row for that instant means done."""
    row = device.db.execute(
        "SELECT count(*) FROM occurrence_completions "
        "WHERE deleted_at IS NULL AND task_id = ? AND occurrence = ?",
        (task_id, wire_time(occurrence)),
    ).fetchone()
    return row[0] > 0


async def a_repeating_task(api, email: str = "alice@example.com") -> tuple[Device, str]:
    device = await register_without_syncing(api, email, "Alice")
    task_id = device.create_task(
        "Вынести мусор", starts_at=wire_time(START), rrule="FREQ=WEEKLY"
    )
    return device, task_id


async def test_one_tuesday_is_done_and_the_next_is_not(api):
    device, task = await a_repeating_task(api)

    tick(device, task, START)

    assert done(device, task, START)
    assert not done(device, task, START + timedelta(days=7))


async def test_the_rule_is_untouched(api):
    """Done is not skipped: the instant still exists, it is just ticked."""
    device, task = await a_repeating_task(api)

    tick(device, task, START)

    assert device.task(task)["recurrence_exceptions"] == "[]"


async def test_the_other_phone_sees_the_tick(api):
    alice, task = await a_repeating_task(api)
    tick(alice, task, START)
    await alice.sync()

    invite = (
        await api.post(
            "/auth/login", json={"email": "alice@example.com", "password": PASSWORD}
        )
    ).json()["invite_code"]
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=invite)

    assert done(bob, task, START)
    assert not done(bob, task, START + timedelta(days=7))


async def test_unticking_reaches_the_other_phone(api):
    alice, task = await a_repeating_task(api)
    completion = tick(alice, task, START)
    await alice.sync()

    invite = (
        await api.post(
            "/auth/login", json={"email": "alice@example.com", "password": PASSWORD}
        )
    ).json()["invite_code"]
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=invite)
    assert done(bob, task, START)

    alice.db.execute(
        "UPDATE occurrence_completions SET deleted_at = ?, updated_at = ?, dirty = 1 "
        "WHERE id = ?",
        (alice.now(), alice.now(), completion),
    )
    alice.db.commit()
    await alice.sync()
    await bob.sync()

    assert not done(bob, task, START)


async def test_both_ticking_the_same_tuesday_offline_is_not_a_conflict(api):
    """Two rows, one answer. This is why there is no unique constraint."""
    alice, task = await a_repeating_task(api)
    await alice.sync()

    invite = (
        await api.post(
            "/auth/login", json={"email": "alice@example.com", "password": PASSWORD}
        )
    ).json()["invite_code"]
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=invite)

    # Both offline, both tick the same instant.
    tick(alice, task, START)
    tick(bob, task, START)

    await alice.sync()
    await bob.sync()
    await alice.sync()

    for device in (alice, bob):
        assert done(device, task, START)
    rows = alice.db.execute(
        "SELECT count(*) FROM occurrence_completions WHERE deleted_at IS NULL"
    ).fetchone()[0]
    assert rows == 2


async def test_ticking_different_tuesdays_offline_keeps_both(api):
    """The reason this is a table and not a list of dates on the task.

    Whole-row last-write-wins would have taken one list and thrown the other
    away. Separate rows do not compete.
    """
    alice, task = await a_repeating_task(api)
    await alice.sync()

    invite = (
        await api.post(
            "/auth/login", json={"email": "alice@example.com", "password": PASSWORD}
        )
    ).json()["invite_code"]
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=invite)

    tick(alice, task, START)
    tick(bob, task, START + timedelta(days=7))

    await alice.sync()
    await bob.sync()
    await alice.sync()

    for device in (alice, bob):
        assert done(device, task, START)
        assert done(device, task, START + timedelta(days=7))
