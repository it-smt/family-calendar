"""The first run, before the network has been heard from.

Every other device test in this suite registers and then immediately syncs,
which is how a real bug hid behind 698 passing tests: the pull was what put the
household and the user into the device's database, and every table in the
schema has `household_id NOT NULL REFERENCES households (id)` with foreign keys
on. A device that had not yet completed a pull could not insert a single row —
not a task, not a category, not an item on the shopping list. The failure was
silent, so the app simply appeared to add nothing.

These tests hold the device on the ground: it registers, never syncs, and has
to work anyway. That is the whole premise of the thing — the local database is
the source of truth and the UI never waits for the network.
"""

from __future__ import annotations

import sqlite3
import uuid
from datetime import UTC, datetime

import pytest

from tests.device import Device, wire_time
from tests.test_offline_convergence import PASSWORD, enrol


async def register_without_syncing(api, email: str, name: str) -> Device:
    """Everything sign-in does, and then nothing else. No push, no pull."""
    response = await api.post(
        "/auth/register",
        json={"email": email, "password": PASSWORD, "display_name": name},
    )
    assert response.status_code == 201, response.text
    body = response.json()
    return Device(
        api,
        token=body["access_token"],
        household_id=body["household_id"],
        user_id=body["user_id"],
        name=name,
    )


async def test_a_device_that_has_never_synced_can_create_things(api):
    device = await register_without_syncing(api, "alice@example.com", "Alice")

    device.create_task("Врач в 16:00")

    assert [task["title"] for task in device.live_tasks()] == ["Врач в 16:00"]
    assert device.dirty_count() == 1


@pytest.mark.parametrize(
    ("table", "columns"),
    [
        (
            "categories",
            {"name": "Дом", "color_hex": "#4DABF7"},
        ),
        (
            "packing_templates",
            {"name": "Бассейн", "items": "[]"},
        ),
        (
            "shopping_items",
            {"title": "Молоко", "added_by": None},
        ),
    ],
)
async def test_every_kind_of_row_can_be_written_before_the_first_sync(
    api, table: str, columns: dict
):
    """The bug hit all of them at once, so all of them are checked."""
    device = await register_without_syncing(api, "alice@example.com", "Alice")

    values = {
        "id": str(uuid.uuid4()).upper(),
        "household_id": device.household_id,
        "created_at": device.now(),
        "updated_at": device.now(),
        "updated_by": device.user_id,
        "dirty": 1,
        **{
            key: (device.user_id if value is None else value)
            for key, value in columns.items()
        },
    }
    names = ", ".join(values)
    placeholders = ", ".join(f":{name}" for name in values)
    device.db.execute(f"INSERT INTO {table} ({names}) VALUES ({placeholders})", values)
    device.db.commit()

    assert device.db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 1


async def test_the_foreign_keys_are_what_made_it_fail(api):
    """Why the rows are written at sign-in, stated as a test.

    Remove them and the very first task throws. Keeping this here means the
    next person to wonder why sign-in touches the database has an answer that
    cannot go stale.
    """
    device = await register_without_syncing(api, "alice@example.com", "Alice")
    device.db.execute("DELETE FROM users")
    device.db.execute("DELETE FROM households")
    device.db.commit()

    with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
        device.create_task("Врач в 16:00")


async def test_work_done_before_the_first_sync_reaches_the_other_phone(api):
    """Offline from the first second, and none of it lost."""
    alice = await register_without_syncing(api, "alice@example.com", "Alice")
    task_id = alice.create_task("Врач в 16:00")

    await alice.sync()

    invite = (
        await api.post(
            "/auth/login", json={"email": "alice@example.com", "password": PASSWORD}
        )
    ).json()["invite_code"]
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=invite)

    assert [task["title"] for task in bob.live_tasks()] == ["Врач в 16:00"]
    assert bob.task(task_id)["created_by"] == alice.user_id


async def test_the_stand_in_rows_are_never_pushed(api):
    """A made-up household name must not reach the server.

    The rows written at sign-in are guesses — on the joining device the
    household name is not even known. They are written clean, so the outbox
    never picks them up; if it ever did, last-write-wins would let a
    placeholder overwrite the real name for both people.
    """
    alice = await register_without_syncing(api, "alice@example.com", "Alice")

    outbox = alice.collect_outbox()

    assert outbox == []
    assert alice.dirty_count() == 0


async def test_the_server_replaces_the_stand_in_rows(api):
    """They lose to the real ones on the first pull, by ordinary last-write-wins."""
    alice = await register_without_syncing(api, "alice@example.com", "Alice")
    before = alice.db.execute("SELECT name, invite_code FROM households").fetchone()
    # The stand-in code is the household's own id, which is unique by
    # construction — an empty string would collide with the next household's
    # stand-in, and the unique index on live invite codes would drop one of them.
    assert before["invite_code"] == alice.household_id

    await alice.sync()

    household = alice.db.execute("SELECT * FROM households").fetchone()
    user = alice.db.execute("SELECT * FROM users").fetchone()
    assert len(household["invite_code"]) == 8
    assert household["updated_at"] > wire_time(datetime.fromtimestamp(0, UTC))
    assert user["display_name"] == "Alice"
    assert alice.dirty_count() == 0


async def test_a_second_account_gets_a_database_of_its_own(api):
    """One phone, one household at a time.

    Two households in one database is what used to happen, and it broke twice
    over: their tasks sat in the list together, and the stand-in rows collided
    on the unique index over live invite codes — which `INSERT OR IGNORE`, as
    it first was, swallowed, leaving every row of the second household failing
    its foreign key at COMMIT.

    Now the first household is cleared out, so neither can happen. The
    placeholder invite code stays unique anyway: one of those two faults was
    silent, and belt and braces cost nothing here.
    """
    alice = await register_without_syncing(api, "alice@example.com", "Alice")

    alice.household_id = str(uuid.uuid4()).upper()
    alice.user_id = str(uuid.uuid4()).upper()
    alice.write_local_identity()

    rows = alice.db.execute("SELECT id, invite_code FROM households").fetchall()
    assert [row["id"] for row in rows] == [alice.household_id]
    assert rows[0]["invite_code"] == alice.household_id

    alice.create_task("Второй дом")
    assert [task["title"] for task in alice.live_tasks()] == ["Второй дом"]


async def test_signing_in_as_another_household_clears_the_first_one_out(api):
    """A phone belongs to one household at a time.

    Left alone, the previous account's tasks would sit in the list next to the
    new one's — visible, and indistinguishable from your own. They are not this
    device's to keep: nothing here was ever pushed by it, and a tombstone would
    be an edit to somebody else's data.
    """
    alice = await register_without_syncing(api, "alice@example.com", "Alice")
    alice.create_task("Чужая задача", starts_at=alice.now())
    assert alice.live_tasks()

    # The same phone, a different account.
    alice.household_id = str(uuid.uuid4()).upper()
    alice.user_id = str(uuid.uuid4()).upper()
    alice.write_local_identity()

    assert alice.live_tasks() == []
    assert alice.cursor == 0
    households = alice.db.execute("SELECT count(*) FROM households").fetchone()[0]
    assert households == 1
