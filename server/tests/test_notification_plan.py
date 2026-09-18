"""Which alerts survive the cut.

iOS drops everything past 64 pending notifications silently, so the planner has
to choose. These check that it chooses the soonest, deterministically, and never
schedules something that has already happened.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from tests.notification_plan_transcription import (
    LIMIT,
    Planned,
    Reminder,
    Task,
    make,
)

NOW = datetime(2026, 9, 18, 9, 0, tzinfo=UTC)


def task(identifier: str, hours_ahead: float, **kwargs) -> Task:
    return Task(
        id=identifier,
        title=identifier,
        starts_at=NOW + timedelta(hours=hours_ahead),
        **kwargs,
    )


def reminder(identifier: str, task_id: str, offset: int = -30, **kwargs) -> Reminder:
    return Reminder(id=identifier, task_id=task_id, offset_minutes=offset, **kwargs)


def test_alerts_come_out_soonest_first():
    tasks = [task("c", 5), task("a", 1), task("b", 3)]
    reminders = {t.id: [reminder(f"r-{t.id}", t.id)] for t in tasks}

    plan = make(tasks, reminders, now=NOW)

    assert [item.task_id for item in plan] == ["a", "b", "c"]


def test_the_cut_keeps_the_nearest_ones():
    """A daily task must not push out tomorrow's dentist by filling the budget."""
    tasks = [task(str(index), index + 1) for index in range(80)]
    reminders = {t.id: [reminder(f"r-{t.id}", t.id, offset=0)] for t in tasks}

    plan = make(tasks, reminders, now=NOW)

    assert len(plan) == LIMIT
    assert [item.task_id for item in plan] == [str(index) for index in range(LIMIT)]


def test_a_recurring_task_cannot_take_the_whole_budget_on_its_own():
    """It can fill it — but only with occurrences nearer than everything else."""
    daily = Task(id="daily", title="Pills", starts_at=NOW + timedelta(hours=2), rrule="FREQ=DAILY")
    soon = task("dentist", 1)
    tasks = [daily, soon]
    reminders = {
        "daily": [reminder("r-daily", "daily", offset=0)],
        "dentist": [reminder("r-dentist", "dentist", offset=0)],
    }

    plan = make(tasks, reminders, now=NOW)

    assert len(plan) == LIMIT
    assert plan[0].task_id == "dentist"
    assert plan[1].task_id == "daily"
    # Every scheduled instant is still ahead, and they are in order.
    assert all(item.fire_at > NOW for item in plan)
    assert [item.fire_at for item in plan] == sorted(item.fire_at for item in plan)


def test_alerts_in_the_past_are_never_scheduled():
    tasks = [task("already", 0.25)]
    reminders = {"already": [reminder("r", "already", offset=-30)]}

    assert make(tasks, reminders, now=NOW) == []


def test_finished_deleted_and_geofenced_things_are_left_out():
    tasks = [
        task("done", 1, completed=True),
        task("gone", 2, deleted=True),
        task("geo", 3),
        task("plain", 4),
    ]
    reminders = {
        "done": [reminder("r1", "done")],
        "gone": [reminder("r2", "gone")],
        # Geofences are regions, rationed separately, not pending alerts.
        "geo": [reminder("r3", "geo", kind="geo")],
        "plain": [reminder("r4", "plain")],
    }

    plan = make(tasks, reminders, now=NOW)

    assert [item.task_id for item in plan] == ["plain"]


def test_a_task_with_no_reminder_schedules_nothing():
    assert make([task("silent", 1)], {}, now=NOW) == []


def test_two_alerts_at_the_same_instant_cut_the_same_way_every_time():
    """Otherwise the set churns on every reschedule."""
    tasks = [task(f"t{index}", 1) for index in range(4)]
    reminders = {t.id: [reminder(f"r-{t.id}", t.id, offset=0)] for t in tasks}

    first = make(tasks, reminders, now=NOW, limit=2)
    second = make(list(reversed(tasks)), reminders, now=NOW, limit=2)

    assert [item.identifier for item in first] == [item.identifier for item in second]


def test_one_task_with_several_reminders_gets_one_alert_each():
    tasks = [task("pool", 5)]
    reminders = {
        "pool": [
            reminder("day-before", "pool", offset=-60 * 24),
            reminder("hour-before", "pool", offset=-60),
            reminder("at-the-time", "pool", offset=0),
        ]
    }

    plan = make(tasks, reminders, now=NOW)

    assert [item.reminder_id for item in plan] == ["hour-before", "at-the-time"]
    # The day-before one already passed, so it is not scheduled.
    assert all(item.fire_at > NOW for item in plan)


# --- leave-time reminders --------------------------------------------------

from tests.travel_transcription import TravelEstimate  # noqa: E402


def estimate(minutes: float, source: str = "cached") -> TravelEstimate:
    return TravelEstimate(
        duration=minutes * 60, distance=8000, source=source, measured_at=NOW
    )


def test_a_leave_time_reminder_counts_back_from_the_door():
    """Not from the appointment: the journey is what the person has to allow for."""
    tasks = [task("clinic", 3)]
    reminders = {"clinic": [reminder("r", "clinic", offset=0, kind="leave_time")]}

    plan = make(tasks, reminders, now=NOW, estimates={"clinic": estimate(25)})

    appointment = NOW + timedelta(hours=3)
    assert plan[0].fire_at == appointment - timedelta(minutes=25) - timedelta(minutes=5)


def test_being_warned_before_leaving_shifts_the_alert_earlier_still():
    tasks = [task("clinic", 3)]
    reminders = {"clinic": [reminder("r", "clinic", offset=-10, kind="leave_time")]}

    plan = make(tasks, reminders, now=NOW, estimates={"clinic": estimate(25)})

    appointment = NOW + timedelta(hours=3)
    assert plan[0].fire_at == appointment - timedelta(minutes=25 + 5 + 10)


def test_a_longer_journey_rings_earlier():
    tasks = [task("clinic", 3)]
    reminders = {"clinic": [reminder("r", "clinic", offset=0, kind="leave_time")]}

    near = make(tasks, reminders, now=NOW, estimates={"clinic": estimate(10)})
    far = make(tasks, reminders, now=NOW, estimates={"clinic": estimate(45)})

    assert far[0].fire_at < near[0].fire_at


def test_without_an_estimate_it_still_rings():
    """No route, no location, no network — silence would be the worst answer."""
    tasks = [task("clinic", 3)]
    reminders = {"clinic": [reminder("r", "clinic", offset=-30, kind="leave_time")]}

    plan = make(tasks, reminders, now=NOW, estimates={})

    assert len(plan) == 1
    assert plan[0].fire_at == NOW + timedelta(hours=3) - timedelta(minutes=30)


def test_an_estimate_that_puts_leaving_in_the_past_schedules_nothing():
    """The moment has gone; ringing about it would only be noise."""
    tasks = [task("clinic", 0.2)]
    reminders = {"clinic": [reminder("r", "clinic", offset=0, kind="leave_time")]}

    plan = make(tasks, reminders, now=NOW, estimates={"clinic": estimate(30)})

    assert plan == []
