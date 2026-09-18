"""Which places the phone watches for.

iOS refuses to monitor more than 20 regions and says nothing about the rest, so
a household with more geofenced reminders than that gets whichever 20 this
function picks. The nearest ones are the ones worth watching.
"""

from __future__ import annotations

from tests.geofence_transcription import (
    LIMIT,
    MINIMUM_RADIUS,
    GeoReminder,
    GeoTask,
    differs,
    select,
)
from tests.travel_transcription import GeoPoint

HERE = GeoPoint(55.751244, 37.618423)


def place(km_away: float) -> GeoPoint:
    """A point roughly this many kilometres north of here."""
    return GeoPoint(HERE.latitude + km_away / 111.195, HERE.longitude)


def fenced(identifier: str, km_away: float, **kwargs) -> tuple[GeoTask, GeoReminder]:
    point = place(km_away)
    return (
        GeoTask(id=f"task-{identifier}", title=identifier),
        GeoReminder(
            id=identifier,
            task_id=f"task-{identifier}",
            latitude=point.latitude,
            longitude=point.longitude,
            **kwargs,
        ),
    )


def build(pairs):
    tasks = [task for task, _ in pairs]
    reminders: dict[str, list[GeoReminder]] = {}
    for _, reminder in pairs:
        reminders.setdefault(reminder.task_id, []).append(reminder)
    return tasks, reminders


def test_the_nearest_places_are_the_ones_watched():
    """A fence around a shop in another city is not worth a slot."""
    pairs = [fenced(f"p{index:02d}", km_away=index + 1) for index in range(30)]
    tasks, reminders = build(pairs)

    chosen = select(tasks, reminders, origin=HERE)

    assert len(chosen) == LIMIT
    assert [region.reminder_id for region in chosen] == [f"p{index:02d}" for index in range(LIMIT)]


def test_under_the_limit_everything_is_watched():
    tasks, reminders = build([fenced(f"p{index}", km_away=index + 1) for index in range(5)])

    assert len(select(tasks, reminders, origin=HERE)) == 5


def test_finished_and_deleted_tasks_give_up_their_slots():
    near_done = GeoTask(id="task-done", title="done", completed=True)
    near_gone = GeoTask(id="task-gone", title="gone", deleted=True)
    far_task, far_reminder = fenced("far", km_away=50)

    reminders = {
        "task-done": [GeoReminder("done", "task-done", HERE.latitude, HERE.longitude)],
        "task-gone": [GeoReminder("gone", "task-gone", HERE.latitude, HERE.longitude)],
        "task-far": [far_reminder],
    }
    chosen = select([near_done, near_gone, far_task], reminders, origin=HERE)

    assert [region.reminder_id for region in chosen] == ["far"]


def test_a_fence_that_fires_on_nothing_is_not_watched():
    task, reminder = fenced("silent", km_away=1, on_enter=False, on_exit=False)

    assert select([task], {task.id: [reminder]}, origin=HERE) == []


def test_a_reminder_without_coordinates_is_not_watched():
    task = GeoTask(id="task-nowhere", title="nowhere")
    reminder = GeoReminder("nowhere", "task-nowhere", latitude=None, longitude=None)

    assert select([task], {task.id: [reminder]}, origin=HERE) == []


def test_a_radius_too_small_to_resolve_is_widened():
    """A fence smaller than location can resolve either never fires or fires at random."""
    task, reminder = fenced("tiny", km_away=1, radius=5)

    chosen = select([task], {task.id: [reminder]}, origin=HERE)

    assert chosen[0].radius == MINIMUM_RADIUS


def test_a_generous_radius_is_kept():
    task, reminder = fenced("wide", km_away=1, radius=500)

    assert select([task], {task.id: [reminder]}, origin=HERE)[0].radius == 500


def test_with_nowhere_to_measure_from_the_choice_is_still_stable():
    """No location yet is not a reason to watch nothing, or to churn."""
    pairs = [fenced(f"p{index:02d}", km_away=index + 1) for index in range(30)]
    tasks, reminders = build(pairs)

    first = select(tasks, reminders, origin=None)
    second = select(list(reversed(tasks)), reminders, origin=None)

    assert len(first) == LIMIT
    assert [r.reminder_id for r in first] == [r.reminder_id for r in second]


def test_moving_changes_which_places_are_watched():
    pairs = [fenced(f"p{index:02d}", km_away=index + 1) for index in range(30)]
    tasks, reminders = build(pairs)

    from_here = select(tasks, reminders, origin=HERE)
    from_far_north = select(tasks, reminders, origin=place(40))

    assert [r.reminder_id for r in from_here] != [r.reminder_id for r in from_far_north]
    assert differs(from_here, from_far_north)


def test_an_unchanged_set_is_left_alone():
    """Re-registering a region resets it and can cost a crossing."""
    tasks, reminders = build([fenced(f"p{index}", km_away=index + 1) for index in range(3)])

    chosen = select(tasks, reminders, origin=HERE)

    assert not differs(chosen, select(tasks, reminders, origin=HERE))
    # A small move that does not change the set is not a reason to re-register.
    assert not differs(chosen, select(tasks, reminders, origin=place(0.2)))
