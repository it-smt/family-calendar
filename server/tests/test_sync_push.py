"""POST /sync/push."""

from __future__ import annotations

import uuid

from sqlalchemy import text

from tests.conftest import Family, change, task_payload, wire_time


async def test_a_pushed_task_comes_back_in_the_server_version(api, family: Family):
    payload = task_payload(family, title="Doctor at 16:00")

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(),
    )

    assert response.status_code == 200
    body = response.json()
    applied = [c for c in body["applied"] if c["entity_type"] == "task"]
    assert len(applied) == 1
    assert applied[0]["payload"]["title"] == "Doctor at 16:00"
    # The server fills in what the device left out, and hands the row back whole.
    assert applied[0]["payload"]["travel_mode"] == "none"
    assert applied[0]["payload"]["created_at"] is not None
    assert body["server_cursor"] > 0


async def test_uuids_and_timestamps_come_back_in_the_wire_format(api, family: Family):
    task_id = uuid.uuid4()
    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(family, task_id=task_id))]},
        headers=family.headers(),
    )

    payload = response.json()["applied"][0]["payload"]
    assert payload["id"] == str(task_id).upper()
    assert payload["updated_at"].endswith("Z")
    assert payload["updated_at"] == wire_time()


async def test_pushing_the_same_row_twice_changes_nothing_the_second_time(
    api, family: Family
):
    body = {"changes": [change("task", task_payload(family))]}

    first = (await api.post("/sync/push", json=body, headers=family.headers())).json()
    second = (await api.post("/sync/push", json=body, headers=family.headers())).json()

    assert first["applied"]
    # Nothing changed, so nothing was logged: an idempotent re-push must not
    # move the cursor, or two devices would keep waking each other up.
    assert second["applied"] == []
    assert second["server_cursor"] == 0

    # The task and the feed entry it produced, and nothing from the second push.
    pulled = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()
    assert [c["entity_type"] for c in pulled["changes"]] == ["task", "activity_entry"]


async def test_a_whole_batch_lands_at_once(api, family: Family, db_engine):
    payloads = [task_payload(family, title=f"Task {index}") for index in range(20)]

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload) for payload in payloads]},
        headers=family.headers(),
    )

    assert response.status_code == 200
    async with db_engine.connect() as connection:
        count = await connection.scalar(text("SELECT count(*) FROM tasks"))
    assert count == 20


async def test_a_batch_with_one_broken_row_lands_not_at_all(
    api, family: Family, db_engine
):
    """Either the whole push happened or it did not."""
    good = task_payload(family, title="Fine")
    # References a user who does not exist: the deferred foreign key fails at
    # COMMIT, after every row in the batch has been written.
    broken = task_payload(family, title="Broken")
    broken["created_by"] = str(uuid.uuid4())

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", good), change("task", broken)]},
        headers=family.headers(),
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "missing_reference"

    async with db_engine.connect() as connection:
        count = await connection.scalar(text("SELECT count(*) FROM tasks"))
        logged = await connection.scalar(text("SELECT count(*) FROM change_log"))
    assert count == 0
    assert logged == 0


async def test_an_unknown_entity_type_is_rejected(api, family: Family):
    response = await api.post(
        "/sync/push",
        json={"changes": [change("recipe", {"id": str(uuid.uuid4())})]},
        headers=family.headers(),
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "unknown_entity_type"


async def test_a_device_cannot_push_an_activity_entry(api, family: Family):
    """The feed is written here. A device pushing one back would start a loop."""
    response = await api.post(
        "/sync/push",
        json={
            "changes": [
                change(
                    "activity_entry",
                    {
                        "id": str(uuid.uuid4()),
                        "actor_id": str(family.alice_id),
                        "entity_type": "task",
                        "entity_id": str(uuid.uuid4()),
                        "action": "created",
                        "summary": "made up",
                        "updated_at": wire_time(),
                    },
                )
            ]
        },
        headers=family.headers(),
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "unknown_entity_type"


async def test_a_payload_without_updated_at_is_rejected(api, family: Family):
    """`updated_at` decides every conflict. A row without one is a broken client."""
    payload = task_payload(family)
    del payload["updated_at"]

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(),
    )

    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["error"] == "invalid_payload"
    assert [problem["loc"] for problem in detail["problems"]] == [["updated_at"]]


async def test_an_unknown_column_is_rejected(api, family: Family):
    """A column the server does not know means the two schemas have drifted."""
    payload = task_payload(family)
    payload["priority"] = 3

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(),
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "invalid_payload"


async def test_a_push_cannot_write_into_another_household(
    api, family: Family, other_family: Family, db_engine
):
    payload = task_payload(family, title="Trespassing")
    payload["household_id"] = str(other_family.household_id)

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(),
    )

    assert response.status_code == 200
    async with db_engine.connect() as connection:
        owner = await connection.scalar(
            text("SELECT household_id FROM tasks WHERE title = 'Trespassing'")
        )
    assert owner == family.household_id


async def test_updated_by_defaults_to_the_pushing_user(api, family: Family):
    payload = task_payload(family)
    del payload["updated_by"]

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", payload)]},
        headers=family.headers(family.bob_id),
    )

    assert response.json()["applied"][0]["payload"]["updated_by"] == str(
        family.bob_id
    ).upper()
