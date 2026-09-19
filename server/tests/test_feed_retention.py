"""The change feed is the one table that only ever grew.

Every edit adds a row, nothing ever removed one, and the rows travel to a fresh
install along with everything else. After a year of ordinary use a household
carries thousands of them, and no screen reads past the first hundred.

Both sides drop the same rows by the same rule — older than ninety days — so
they converge without either telling the other. These tests are the server's
half; the device's is the same arithmetic against its own copy.
"""

from __future__ import annotations


from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.sync.retention import RETENTION
from tests.conftest import Family, change, task_payload


async def push_a_task(api, family: Family, title: str) -> str:
    payload = task_payload(family, title=title)
    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(),
    )
    assert response.status_code == 200, response.text
    return payload["id"]


async def age_the_feed(engine: AsyncEngine, *, days: int) -> None:
    """Moves every feed entry back in time."""
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "UPDATE activity_entries "
                "SET created_at = created_at - make_interval(days => :days)"
            ),
            {"days": days},
        )


async def feed_size(engine: AsyncEngine) -> tuple[int, int]:
    async with engine.begin() as connection:
        entries = await connection.scalar(text("SELECT count(*) FROM activity_entries"))
        logged = await connection.scalar(
            text("SELECT count(*) FROM change_log WHERE entity_type = 'activity_entry'")
        )
    return entries, logged


async def test_an_old_entry_is_dropped_on_the_next_push(api, family, db_engine):
    await push_a_task(api, family, "Старое")
    await age_the_feed(db_engine, days=RETENTION.days + 1)

    await push_a_task(api, family, "Новое")

    entries, logged = await feed_size(db_engine)
    assert entries == 1
    assert logged == 1


async def test_a_recent_entry_is_kept(api, family, db_engine):
    await push_a_task(api, family, "Старое")
    await age_the_feed(db_engine, days=RETENTION.days - 1)

    await push_a_task(api, family, "Новое")

    entries, _ = await feed_size(db_engine)
    assert entries == 2


async def test_a_device_catching_up_never_sees_a_dropped_entry(api, family, db_engine):
    """The log row goes with the entry, or a fresh install is handed a ghost."""
    await push_a_task(api, family, "Старое")
    await age_the_feed(db_engine, days=RETENTION.days + 1)
    await push_a_task(api, family, "Новое")

    response = await api.get(
        "/sync/pull",
        params={"since": 0, "limit": 500},
        headers=family.headers(family.bob_id),
    )
    assert response.status_code == 200, response.text

    feed = [
        item
        for item in response.json()["changes"]
        if item["entity_type"] == "activity_entry"
    ]
    assert len(feed) == 1
    assert "Новое" in feed[0]["payload"]["summary"]


async def test_one_household_does_not_prune_another(api, family, other_family, db_engine):
    await push_a_task(api, family, "Старое")
    await push_a_task(api, other_family, "Чужое старое")
    await age_the_feed(db_engine, days=RETENTION.days + 1)

    await push_a_task(api, family, "Новое")

    async with db_engine.begin() as connection:
        theirs = await connection.scalar(
            text("SELECT count(*) FROM activity_entries WHERE household_id = :h"),
            {"h": other_family.household_id},
        )
    assert theirs == 1
