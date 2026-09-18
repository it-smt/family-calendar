"""Conflict resolution.

Two rules that pull in different directions: last-write-wins on `updated_at`,
and deletion always wins. These tests pin down what happens where they meet.
"""

from __future__ import annotations

import asyncio
import uuid

from sqlalchemy import text

from tests.conftest import Family, change, task_payload, wire_time


async def push(api, family: Family, payload: dict, user_id: uuid.UUID | None = None):
    return await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(user_id),
    )


async def read_task(db_engine, task_id: uuid.UUID) -> dict:
    async with db_engine.connect() as connection:
        row = (
            await connection.execute(
                text(
                    "SELECT title, notes, updated_at, updated_by, deleted_at "
                    "FROM tasks WHERE id = :i"
                ),
                {"i": task_id},
            )
        ).one()
    return dict(row._mapping)


async def test_the_newer_edit_wins(api, family: Family, db_engine):
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, title="First", updated_at=wire_time(0)))
    await push(api, family, task_payload(family, task_id=task_id, title="Second", updated_at=wire_time(5)))

    assert (await read_task(db_engine, task_id))["title"] == "Second"


async def test_an_older_edit_loses_and_changes_nothing(api, family: Family, db_engine):
    """A device that was offline does not overwrite newer work when it catches up."""
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, title="Newer", updated_at=wire_time(5)))

    response = await push(
        api, family, task_payload(family, task_id=task_id, title="Older", updated_at=wire_time(0))
    )

    assert response.json()["applied"] == []
    # A loss is not a change, so it leaves no trace in the log.
    assert response.json()["server_cursor"] == 0
    assert (await read_task(db_engine, task_id))["title"] == "Newer"


async def test_a_deletion_beats_a_newer_edit(api, family: Family, db_engine):
    """Deletion wins whatever the clocks say."""
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, title="Alive", updated_at=wire_time(10)))

    response = await push(
        api,
        family,
        task_payload(
            family,
            task_id=task_id,
            title="Stale name",
            updated_at=wire_time(1),
            deleted_at=wire_time(1),
        ),
    )

    assert response.json()["applied"], "the tombstone must be applied"
    row = await read_task(db_engine, task_id)
    assert row["deleted_at"] is not None
    # The tombstone lost on time, so it applied only the deletion: the newer
    # title stays, because clobbering it would lose the partner's edit for no
    # reason.
    assert row["title"] == "Alive"


async def test_a_deletion_beats_an_older_edit(api, family: Family, db_engine):
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, title="Alive", updated_at=wire_time(1)))

    await push(
        api,
        family,
        task_payload(
            family, task_id=task_id, title="Gone", updated_at=wire_time(5), deleted_at=wire_time(5)
        ),
    )

    row = await read_task(db_engine, task_id)
    assert row["deleted_at"] is not None
    assert row["title"] == "Gone"


async def test_a_deleted_row_is_never_resurrected(api, family: Family, db_engine):
    """Not even by an edit from the far future."""
    task_id = uuid.uuid4()
    await push(
        api,
        family,
        task_payload(family, task_id=task_id, title="Gone", updated_at=wire_time(1), deleted_at=wire_time(1)),
    )

    await push(
        api,
        family,
        task_payload(family, task_id=task_id, title="Back?", updated_at=wire_time(999), deleted_at=None),
    )

    row = await read_task(db_engine, task_id)
    assert row["deleted_at"] is not None


async def test_the_row_clock_never_runs_backwards(api, family: Family, db_engine):
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, updated_at=wire_time(10)))

    await push(
        api,
        family,
        task_payload(family, task_id=task_id, updated_at=wire_time(1), deleted_at=wire_time(1)),
    )

    row = await read_task(db_engine, task_id)
    assert row["updated_at"].isoformat().startswith("2026-09-18T09:10")


async def test_identical_timestamps_are_broken_the_same_way_every_time(
    api, family: Family, other_family: Family, db_engine
):
    """Two devices, two clocks, the same second. Order of arrival must not decide."""
    winner = max(family.alice_id, family.bob_id)
    loser = min(family.alice_id, family.bob_id)

    first_id, second_id = uuid.uuid4(), uuid.uuid4()
    moment = wire_time(3)

    # Same row, same timestamp, pushed loser-first.
    await push(api, family, task_payload(family, task_id=first_id, title="loser", updated_at=moment, updated_by=loser))
    await push(api, family, task_payload(family, task_id=first_id, title="winner", updated_at=moment, updated_by=winner))

    # And again, pushed winner-first.
    await push(api, family, task_payload(family, task_id=second_id, title="winner", updated_at=moment, updated_by=winner))
    await push(api, family, task_payload(family, task_id=second_id, title="loser", updated_at=moment, updated_by=loser))

    assert (await read_task(db_engine, first_id))["title"] == "winner"
    assert (await read_task(db_engine, second_id))["title"] == "winner"


async def test_two_devices_pushing_the_same_row_at_once(api, family: Family, db_engine):
    """The real race: both read the old row, both think they are newer."""
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, title="Original", updated_at=wire_time(0)))

    await asyncio.gather(
        push(api, family, task_payload(family, task_id=task_id, title="Alice", updated_at=wire_time(1)), family.alice_id),
        push(api, family, task_payload(family, task_id=task_id, title="Bob", updated_at=wire_time(2)), family.bob_id),
    )

    # Bob's timestamp is newer, so Bob wins — whichever of them reached the
    # server first.
    assert (await read_task(db_engine, task_id))["title"] == "Bob"


async def test_concurrent_pushes_leave_a_gapless_log(api, family: Family):
    """The cursor must never step over a change that lands late.

    `change_log.seq` is handed out at insert time but becomes visible at commit
    time. Without the per-household lock, a device could pull, see seq 6, move
    its cursor, and never learn about the seq 5 that committed a moment later.
    """
    await asyncio.gather(
        *(
            push(api, family, task_payload(family, title=f"Task {index}", updated_at=wire_time(index)))
            for index in range(12)
        )
    )

    body = (
        await api.get("/sync/pull", params={"since": 0, "limit": 100}, headers=family.headers())
    ).json()
    seqs = [c["seq"] for c in body["changes"]]

    assert len(seqs) == 24  # 12 tasks, 12 feed entries
    assert seqs == list(range(min(seqs), min(seqs) + len(seqs)))


async def test_a_delete_and_an_edit_racing(api, family: Family, db_engine):
    task_id = uuid.uuid4()
    await push(api, family, task_payload(family, task_id=task_id, title="Doctor", updated_at=wire_time(0)))

    await asyncio.gather(
        push(api, family, task_payload(family, task_id=task_id, title="Doctor at 16:00", updated_at=wire_time(9)), family.alice_id),
        push(api, family, task_payload(family, task_id=task_id, title="Doctor", updated_at=wire_time(1), deleted_at=wire_time(1)), family.bob_id),
    )

    # Deletion wins either way: it is the one outcome both devices agree on
    # without having to compare clocks.
    assert (await read_task(db_engine, task_id))["deleted_at"] is not None


async def _apply_one(session, family: Family, payload: dict) -> None:
    """Call the sync core directly, so the test controls the transaction."""
    from app.sync.apply import apply_push
    from app.sync.schemas import validate_payload

    await apply_push(
        session,
        household_id=family.household_id,
        user_id=family.alice_id,
        changes=[("task", validate_payload("task", payload))],
    )


async def test_pushes_in_one_household_are_serialised(db_engine, family: Family):
    """The lock that keeps the cursor honest.

    `change_log.seq` is assigned when a row is inserted, but only becomes
    visible when its transaction commits. If a second push could take seq 6
    while the first still holds an uncommitted seq 5, a device that pulled in
    between would advance its cursor past 6 and lose seq 5 for good.

    So the second push has to wait. This test asserts exactly that: it does not
    finish while the first transaction is open.
    """
    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False, autoflush=False)

    async with factory() as first, factory() as second:
        first_transaction = await first.begin()
        await _apply_one(first, family, task_payload(family, title="First"))

        async def second_push() -> None:
            async with second.begin():
                await _apply_one(second, family, task_payload(family, title="Second"))

        blocked = asyncio.create_task(second_push())
        await asyncio.sleep(0.3)
        assert not blocked.done(), "the second push took a sequence number too early"

        await first_transaction.commit()
        await asyncio.wait_for(blocked, timeout=5)


async def test_another_household_is_never_held_up(
    db_engine, family: Family, other_family: Family
):
    """The lock is per household, so the two of them never wait on each other."""
    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False, autoflush=False)

    async with factory() as first, factory() as second:
        first_transaction = await first.begin()
        await _apply_one(first, family, task_payload(family, title="Ours"))

        async def other_push() -> None:
            async with second.begin():
                await _apply_one(second, other_family, task_payload(other_family, title="Theirs"))

        await asyncio.wait_for(asyncio.create_task(other_push()), timeout=5)
        await first_transaction.commit()
