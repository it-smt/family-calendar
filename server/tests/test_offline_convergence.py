"""The device side of the protocol, against the real server.

The stage 4 test from the spec is `test_twenty_tasks_made_in_flight_mode`: work
offline for a while, come back, and end up with the same data on both phones.
The rest pin down the places where an offline-first client usually loses an
edit.
"""

from __future__ import annotations

import asyncio
from datetime import timedelta

import pytest

from tests.device import Device, skewed_clock, wire_time

PASSWORD = "correct horse battery"


async def enrol(api, email: str, name: str, invite_code: str | None = None, **kwargs) -> Device:
    """Register or join, then bring the new device up to date."""
    if invite_code is None:
        response = await api.post(
            "/auth/register",
            json={"email": email, "password": PASSWORD, "display_name": name},
        )
    else:
        response = await api.post(
            "/auth/join",
            json={
                "email": email,
                "password": PASSWORD,
                "display_name": name,
                "invite_code": invite_code,
            },
        )
    assert response.status_code == 201, response.text
    body = response.json()

    device = Device(
        api,
        token=body["access_token"],
        household_id=body["household_id"],
        user_id=body["user_id"],
        name=name,
        **kwargs,
    )
    await device.sync()
    return device


@pytest.fixture
def invite_code_holder() -> dict:
    return {}


async def test_twenty_tasks_made_in_flight_mode(api):
    """The test the spec asks for: twenty tasks offline, then the network."""
    alice = await enrol(api, "alice@example.com", "Alice")

    # Aeroplane mode: nothing here touches the network.
    for index in range(20):
        alice.create_task(f"Task {index}")

    assert len(alice.live_tasks()) == 20
    assert alice.dirty_count() == 20

    await alice.sync()

    assert alice.dirty_count() == 0
    # And the other phone sees all twenty.
    bob = await enrol(api, "bob@example.com", "Bob", invite_code=await invite_of(api, alice))
    await bob.sync()
    assert [task["title"] for task in bob.live_tasks()] == [
        task["title"] for task in alice.live_tasks()
    ]
    assert len(bob.live_tasks()) == 20

    alice.close()
    bob.close()


async def invite_of(api, device: Device) -> str:
    body = (await api.get("/auth/me", headers=device.headers)).json()
    return body["invite_code"]


async def household_of_two(api, **bob_kwargs) -> tuple[Device, Device]:
    alice = await enrol(api, "alice@example.com", "Alice")
    bob = await enrol(
        api, "bob@example.com", "Bob", invite_code=await invite_of(api, alice), **bob_kwargs
    )
    await alice.sync()
    return alice, bob


async def test_two_phones_converge_in_both_directions(api):
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    assert bob.task(task_id)["title"] == "Doctor"

    bob.update_task(task_id, title="Doctor at 16:00")
    await bob.sync()
    await alice.sync()

    assert alice.task(task_id)["title"] == "Doctor at 16:00"
    assert alice.dirty_count() == 0
    assert bob.dirty_count() == 0

    alice.close()
    bob.close()


async def test_an_unpushed_edit_is_not_lost_to_an_older_change(api):
    """The bug an offline-first client is most likely to have.

    Alice edits while offline. Meanwhile an older version of the row arrives
    from the server. Applying it blindly would throw away an edit that has never
    left the phone.
    """
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    # Bob edits and pushes; Alice edits later, offline, and has not pushed.
    bob.update_task(task_id, title="Bob's version")
    await bob.sync()

    alice.clock = skewed_clock(timedelta(minutes=5))
    alice.update_task(task_id, title="Alice's newer version")

    await alice.pull()  # the network comes back, but nothing is sent yet

    assert alice.task(task_id)["title"] == "Alice's newer version"
    assert alice.task(task_id)["dirty"] == 1, "the edit still has to go out"

    # And once it does, Bob gets it.
    await alice.push()
    await bob.sync()
    assert bob.task(task_id)["title"] == "Alice's newer version"

    alice.close()
    bob.close()


async def test_a_newer_change_replaces_an_unpushed_edit_and_clears_the_flag(api):
    """Last-write-wins cuts both ways, and the loser stops being an outbox item."""
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    alice.update_task(task_id, title="Alice, offline")
    bob.clock = skewed_clock(timedelta(minutes=5))
    bob.update_task(task_id, title="Bob, later")
    await bob.sync()

    await alice.pull()

    assert alice.task(task_id)["title"] == "Bob, later"
    # Alice's version no longer exists, so there is nothing left to push.
    assert alice.task(task_id)["dirty"] == 0

    alice.close()
    bob.close()


async def test_a_deletion_from_the_other_phone_wins(api):
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    bob.delete_task(task_id)
    await bob.sync()

    # Alice edits the same task, later, without knowing.
    alice.clock = skewed_clock(timedelta(minutes=5))
    alice.update_task(task_id, title="Still going")
    await alice.sync()
    await bob.sync()

    assert alice.task(task_id)["deleted_at"] is not None
    assert bob.task(task_id)["deleted_at"] is not None
    assert alice.live_tasks() == []
    assert bob.live_tasks() == []

    alice.close()
    bob.close()


async def test_an_edit_made_during_a_push_is_not_marked_clean(api):
    """The narrow window that silently drops an edit.

    The user types while the request is in flight. If the push clears every row
    it sent, that edit is marked as delivered without ever having been sent.
    """
    alice, _ = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    outbox = alice.collect_outbox()

    # The user edits while the request is on the wire.
    alice.update_task(task_id, title="Doctor at 16:00")

    await alice.send(outbox)

    assert alice.task(task_id)["dirty"] == 1
    assert alice.task(task_id)["title"] == "Doctor at 16:00"

    await alice.sync()
    assert alice.dirty_count() == 0

    alice.close()


async def test_a_month_behind_is_walked_page_by_page(api):
    alice, bob = await household_of_two(api)

    for index in range(15):
        alice.create_task(f"Task {index}")
    await alice.sync()

    # A small page size, the way a device with a month of changes would behave.
    applied = await bob.pull(limit=3)

    assert applied >= 15
    assert len(bob.live_tasks()) == 15
    assert bob.cursor > 0

    # Pulling again from the same cursor changes nothing.
    before = bob.cursor
    assert await bob.pull(limit=3) == 0
    assert bob.cursor == before

    alice.close()
    bob.close()


async def test_two_clocks_that_disagree_still_converge(api):
    """Device clocks drift. Both phones must still end up with the same row."""
    alice, bob = await household_of_two(api, clock=skewed_clock(timedelta(minutes=-7)))

    task_id = alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    # Bob's clock is seven minutes behind, so his later edit looks older.
    bob.update_task(task_id, title="Bob")
    alice.update_task(task_id, title="Alice")
    await bob.sync()
    await alice.sync()
    await bob.sync()
    await alice.sync()

    assert alice.task(task_id)["title"] == bob.task(task_id)["title"]
    assert alice.task(task_id)["updated_at"] == bob.task(task_id)["updated_at"]
    assert alice.dirty_count() == 0
    assert bob.dirty_count() == 0

    alice.close()
    bob.close()


async def test_the_partner_appears_in_the_device_database(api):
    """An assignee_id has to point at a user the device has heard of."""
    alice, bob = await household_of_two(api)
    await alice.sync()

    names = [
        row["display_name"]
        for row in alice.db.execute("SELECT display_name FROM users ORDER BY created_at")
    ]

    assert names == ["Alice", "Bob"]

    alice.close()
    bob.close()


async def test_the_activity_feed_reaches_the_device(api):
    alice, bob = await household_of_two(api)

    alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    entries = [
        dict(row)
        for row in bob.db.execute("SELECT action, summary, entity_type FROM activity_entries")
    ]

    assert {"action": "created", "summary": "Doctor", "entity_type": "task"} in entries

    alice.close()
    bob.close()


def test_wire_timestamps_sort_lexicographically():
    """What the row-value comparison in the generated SQL depends on.

    The device compares timestamps as text. That is only correct while every
    timestamp has the same fixed shape — one written without milliseconds would
    sort after one with them, and last-write-wins would quietly invert.
    """
    from datetime import UTC, datetime

    moments = [
        datetime(2026, 9, 18, 9, 0, 0, 0, tzinfo=UTC),
        datetime(2026, 9, 18, 9, 0, 0, 500_000, tzinfo=UTC),
        datetime(2026, 9, 18, 9, 0, 1, 0, tzinfo=UTC),
        datetime(2026, 9, 18, 10, 0, 0, 0, tzinfo=UTC),
        datetime(2026, 12, 31, 23, 59, 59, 999_000, tzinfo=UTC),
        datetime(2027, 1, 1, 0, 0, 0, 0, tzinfo=UTC),
    ]
    written = [wire_time(moment) for moment in moments]

    assert written == sorted(written)
    assert all(len(value) == len(written[0]) for value in written)


async def test_a_second_edit_in_the_same_millisecond_is_not_swallowed(api):
    """Version stamps have to be strictly increasing, not merely current.

    Timestamps on the wire carry milliseconds, so two edits close together can
    land on the same one. Once the first has been pushed, the second is a row
    the server already considers current: last-write-wins sees an equal stamp
    from an equal author, decides nothing changed, and the edit is gone for
    good — locally clean, never delivered.
    """
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    await alice.sync()

    # A clock that does not move, which is what two quick edits look like once
    # the timestamps are truncated to milliseconds.
    frozen = alice.clock()
    alice.clock = lambda: frozen

    alice.update_task(task_id, title="First edit")
    await alice.sync()
    alice.update_task(task_id, title="Second edit")
    await alice.sync()

    await bob.sync()

    assert alice.task(task_id)["title"] == "Second edit"
    assert bob.task(task_id)["title"] == "Second edit"
    assert alice.dirty_count() == 0

    alice.close()
    bob.close()


async def test_both_edit_the_same_task_offline_and_reconnect_together(api):
    """What last-write-wins costs, written down.

    Two people edit different fields of one task while offline, and the network
    comes back for both at once. The rule compares whole rows, so the later
    stamp wins outright and takes the other person's field with it — the loser
    did not lose an older value, they lost a field the winner never touched.

    This is the protocol the spec asks for, and the test exists so the
    behaviour cannot change by accident. `superseded_edits` is what keeps it
    from being silent.
    """
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor", starts_at="2026-09-20T14:00:00.000Z")
    await alice.sync()
    await bob.sync()

    # Offline, at the same time: she moves it, he renames it.
    alice.update_task(task_id, starts_at="2026-09-20T16:00:00.000Z")
    bob.clock = skewed_clock(timedelta(seconds=30))
    bob.update_task(task_id, title="Doctor — bring the card")

    # Both come back at once.
    await asyncio.gather(alice.sync(), bob.sync())
    await asyncio.gather(alice.sync(), bob.sync())

    # Bob's stamp is later, so Bob's whole row won.
    for device in (alice, bob):
        assert device.task(task_id)["title"] == "Doctor — bring the card"
        assert device.task(task_id)["starts_at"] == "2026-09-20T14:00:00.000Z"

    # And both phones agree, which is the part that matters most.
    assert alice.task(task_id) == bob.task(task_id) or (
        alice.task(task_id)["updated_at"] == bob.task(task_id)["updated_at"]
    )
    assert alice.dirty_count() == 0
    assert bob.dirty_count() == 0

    alice.close()
    bob.close()


async def test_a_replaced_edit_is_kept_so_it_can_be_shown(api):
    """Losing to last-write-wins is allowed. Losing silently is not."""
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor", starts_at="2026-09-20T14:00:00.000Z")
    await alice.sync()
    await bob.sync()

    alice.update_task(task_id, starts_at="2026-09-20T16:00:00.000Z")
    bob.clock = skewed_clock(timedelta(seconds=30))
    bob.update_task(task_id, title="Doctor — bring the card")

    await asyncio.gather(alice.sync(), bob.sync())
    await asyncio.gather(alice.sync(), bob.sync())

    notices = alice.superseded_edits()
    assert len(notices) == 1
    notice = notices[0]
    assert notice["entity_id"] == task_id
    assert notice["actor_id"] == bob.user_id
    # What she had, and what replaced it — enough to show "was 16:00, now 14:00".
    assert notice["mine"]["starts_at"] == "2026-09-20T16:00:00.000Z"
    assert notice["theirs"]["starts_at"] == "2026-09-20T14:00:00.000Z"

    # Bob lost nothing, so Bob is told nothing.
    assert bob.superseded_edits() == []

    alice.close()
    bob.close()


async def test_restoring_a_replaced_edit_is_an_ordinary_write(api):
    """Putting it back needs no special path: it is just a newer edit."""
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor", starts_at="2026-09-20T14:00:00.000Z")
    await alice.sync()
    await bob.sync()

    alice.update_task(task_id, starts_at="2026-09-20T16:00:00.000Z")
    bob.clock = skewed_clock(timedelta(seconds=30))
    bob.update_task(task_id, title="Doctor — bring the card")
    await asyncio.gather(alice.sync(), bob.sync())
    await asyncio.gather(alice.sync(), bob.sync())

    notice = alice.superseded_edits()[0]
    alice.clock = skewed_clock(timedelta(minutes=1))
    alice.update_task(task_id, starts_at=notice["mine"]["starts_at"])
    await alice.sync()
    await bob.sync()

    # Her time is back, and his title survived.
    for device in (alice, bob):
        assert device.task(task_id)["starts_at"] == "2026-09-20T16:00:00.000Z"
        assert device.task(task_id)["title"] == "Doctor — bring the card"

    alice.close()
    bob.close()


async def test_an_ordinary_change_from_the_partner_raises_no_notice(api):
    """Only work that was replaced counts, not every change that arrives."""
    alice, bob = await household_of_two(api)

    task_id = bob.create_task("Bob's errand")
    await bob.sync()
    await alice.sync()

    bob.update_task(task_id, title="Bob's errand, renamed")
    await bob.sync()
    await alice.sync()

    # Alice never wrote to that row, so nothing of hers was replaced.
    assert alice.superseded_edits() == []

    alice.close()
    bob.close()


async def test_an_edit_that_changes_nothing_raises_no_notice(api):
    """A row arriving with the same values is not a lost edit."""
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor")
    await alice.sync()
    await bob.sync()

    # Bob touches the row without changing anything a person would notice.
    bob.clock = skewed_clock(timedelta(seconds=30))
    bob.update_task(task_id, title="Doctor")
    await bob.sync()
    await alice.sync()

    assert alice.superseded_edits() == []

    alice.close()
    bob.close()


async def test_a_rejected_push_also_produces_a_notice(api):
    """The other way an edit is lost: the server refuses it outright.

    When a push carries a row the server considers stale, it applies nothing and
    says so. The device clears the flag either way — it and the server agree on
    what is current. The edit is still gone, so the notice has to come from the
    same place: the pull that brings the winning row back.
    """
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Doctor", starts_at="2026-09-20T14:00:00.000Z")
    await alice.sync()
    await bob.sync()

    # Bob edits and lands first.
    bob.clock = skewed_clock(timedelta(minutes=5))
    bob.update_task(task_id, title="Bob's version")
    await bob.sync()

    # Alice's edit is older, so her push is refused outright.
    alice.update_task(task_id, title="Alice's version")
    pushed = await alice.push()
    assert pushed["applied"] == [], "the push should have been refused as stale"
    assert alice.dirty_count() == 0

    await alice.pull()

    notices = alice.superseded_edits()
    assert len(notices) == 1
    assert notices[0]["mine"]["title"] == "Alice's version"
    assert notices[0]["theirs"]["title"] == "Bob's version"
    assert alice.task(task_id)["title"] == "Bob's version"

    alice.close()
    bob.close()


async def test_the_person_who_asked_finds_out_it_is_done(api):
    """Delegation without this is a label on a row.

    The feed already carries who did what to both phones, so telling the author
    needs no new data — only a way to remember who has been told. The two phones
    keep that separately, because they are told about different things.
    """
    alice, bob = await household_of_two(api)

    # Alice asks Bob to do something.
    task_id = alice.create_task("Book the dentist", assignee_id=bob.user_id)
    await alice.sync()
    await bob.sync()

    assert alice.delegated_work_to_report() == []

    # Bob does it.
    bob.update_task(task_id, completed_at=bob.now())
    await bob.sync()
    await alice.sync()

    waiting = alice.delegated_work_to_report()
    assert len(waiting) == 1
    assert waiting[0]["title"] == "Book the dentist"
    assert waiting[0]["actor_id"] == bob.user_id

    # Bob asked for nothing, so Bob is told nothing.
    assert bob.delegated_work_to_report() == []

    alice.close()
    bob.close()


async def test_finishing_your_own_task_tells_nobody(api):
    """An alert about something you just did yourself is only noise."""
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Buy milk")
    await alice.sync()
    alice.update_task(task_id, completed_at=alice.now())
    await alice.sync()
    await bob.sync()

    assert alice.delegated_work_to_report() == []
    # And Bob did not ask for it, so it is not his business either.
    assert bob.delegated_work_to_report() == []

    alice.close()
    bob.close()


async def test_being_told_once_is_enough(api):
    """A later sync must not bring the same news back."""
    alice, bob = await household_of_two(api)

    task_id = alice.create_task("Book the dentist", assignee_id=bob.user_id)
    await alice.sync()
    await bob.sync()
    bob.update_task(task_id, completed_at=bob.now())
    await bob.sync()
    await alice.sync()

    reported = alice.delegated_work_to_report()
    assert len(reported) == 1

    alice.db.execute(
        "UPDATE activity_entries SET notified = 1 WHERE id = ?", (reported[0]["id"],)
    )
    alice.db.commit()

    await alice.sync()
    assert alice.delegated_work_to_report() == []

    alice.close()
    bob.close()
