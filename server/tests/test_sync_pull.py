"""GET /sync/pull."""

from __future__ import annotations

from tests.conftest import Family, change, task_payload, wire_time


async def push_tasks(api, family: Family, count: int, *, start: int = 0) -> None:
    for index in range(start, start + count):
        response = await api.post(
            "/sync/push",
            json={
                "changes": [
                    change(
                        "task",
                        task_payload(
                            family, title=f"Task {index}", updated_at=wire_time(index)
                        ),
                    )
                ]
            },
            headers=family.headers(),
        )
        assert response.status_code == 200


async def test_pull_from_zero_returns_everything_in_order(api, family: Family):
    await push_tasks(api, family, 3)

    body = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()

    seqs = [c["seq"] for c in body["changes"]]
    assert seqs == sorted(seqs)
    assert body["cursor"] == seqs[-1]
    assert body["has_more"] is False
    assert [c["entity_type"] for c in body["changes"]].count("task") == 3


async def test_pulling_again_from_the_cursor_returns_nothing(api, family: Family):
    await push_tasks(api, family, 2)
    first = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()

    second = (
        await api.get(
            "/sync/pull", params={"since": first["cursor"]}, headers=family.headers()
        )
    ).json()

    assert second["changes"] == []
    assert second["has_more"] is False
    # An empty page must not rewind the device's cursor.
    assert second["cursor"] == first["cursor"]


async def test_a_month_offline_is_walked_page_by_page(api, family: Family):
    """Pagination is mandatory: a device can be behind by any amount."""
    await push_tasks(api, family, 7)

    seen: list[int] = []
    cursor = 0
    pages = 0
    while True:
        body = (
            await api.get(
                "/sync/pull",
                params={"since": cursor, "limit": 3},
                headers=family.headers(),
            )
        ).json()
        seen.extend(c["seq"] for c in body["changes"])
        cursor = body["cursor"]
        pages += 1
        if not body["has_more"]:
            break
        assert pages < 20, "pagination is not terminating"

    assert pages > 1
    assert seen == sorted(seen)
    assert len(seen) == len(set(seen))
    # 7 tasks and the 7 feed entries they produced.
    assert len(seen) == 14


async def test_a_household_never_sees_another_households_changes(
    api, family: Family, other_family: Family
):
    await push_tasks(api, family, 2)
    await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(other_family, title="Theirs"))]},
        headers=other_family.headers(),
    )

    body = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()

    titles = [
        c["payload"].get("title") for c in body["changes"] if c["entity_type"] == "task"
    ]
    assert "Theirs" not in titles
    assert len(titles) == 2


async def test_the_feed_records_who_did_what(api, family: Family):
    await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(family, title="Doctor"))]},
        headers=family.headers(family.bob_id),
    )

    body = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()
    entries = [c for c in body["changes"] if c["entity_type"] == "activity_entry"]

    assert len(entries) == 1
    payload = entries[0]["payload"]
    assert payload["actor_id"] == str(family.bob_id).upper()
    assert payload["action"] == "created"
    # The verb and the label, not a sentence: the phrasing happens on the device.
    assert payload["summary"] == "Doctor"
    assert payload["entity_type"] == "task"


async def test_the_feed_names_what_happened(api, family: Family):
    import uuid

    task_id = uuid.uuid4()
    steps = [
        (task_payload(family, task_id=task_id, updated_at=wire_time(0)), "created"),
        (
            task_payload(family, task_id=task_id, title="Moved", updated_at=wire_time(1)),
            "updated",
        ),
        (
            task_payload(
                family,
                task_id=task_id,
                title="Moved",
                updated_at=wire_time(2),
                completed_at=wire_time(2),
            ),
            "completed",
        ),
        (
            task_payload(
                family,
                task_id=task_id,
                title="Moved",
                updated_at=wire_time(3),
                completed_at=wire_time(2),
                deleted_at=wire_time(3),
            ),
            "deleted",
        ),
    ]

    for payload, _ in steps:
        response = await api.post(
            "/sync/push",
            json={"changes": [change("task", payload)]},
            headers=family.headers(),
        )
        assert response.status_code == 200

    body = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()
    actions = [
        c["payload"]["action"]
        for c in body["changes"]
        if c["entity_type"] == "activity_entry"
    ]

    assert actions == [expected for _, expected in steps]
