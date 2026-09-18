"""A transcription of GeofencePlan.select, in the same shape as the Swift.

iOS monitors at most 20 regions per application and refuses the rest without
saying so, in the same way it drops notifications past 64. Which 20 are chosen
is therefore the feature, not a detail.
"""

from __future__ import annotations

from dataclasses import dataclass

from tests.travel_transcription import GeoPoint

LIMIT = 20
MINIMUM_RADIUS = 100.0


@dataclass(frozen=True)
class GeoReminder:
    id: str
    task_id: str
    latitude: float | None
    longitude: float | None
    radius: float | None = None
    on_enter: bool = True
    on_exit: bool = False
    kind: str = "geo"
    deleted: bool = False


@dataclass(frozen=True)
class GeoTask:
    id: str
    title: str
    deleted: bool = False
    completed: bool = False


@dataclass(frozen=True)
class MonitoredRegion:
    reminder_id: str
    task_id: str
    centre: GeoPoint
    radius: float
    on_enter: bool
    on_exit: bool
    title: str

    @property
    def identifier(self) -> str:
        return self.reminder_id


def select(
    tasks: list[GeoTask],
    reminders: dict[str, list[GeoReminder]],
    origin: GeoPoint | None,
    limit: int = LIMIT,
) -> list[MonitoredRegion]:
    candidates: list[tuple[MonitoredRegion, float]] = []

    for task in tasks:
        if task.deleted or task.completed:
            continue
        for reminder in reminders.get(task.id, []):
            if reminder.deleted or reminder.kind != "geo":
                continue
            if not (reminder.on_enter or reminder.on_exit):
                continue
            if reminder.latitude is None or reminder.longitude is None:
                continue

            centre = GeoPoint(reminder.latitude, reminder.longitude)
            region = MonitoredRegion(
                reminder_id=reminder.id,
                task_id=task.id,
                centre=centre,
                radius=max(reminder.radius or MINIMUM_RADIUS, MINIMUM_RADIUS),
                on_enter=reminder.on_enter,
                on_exit=reminder.on_exit,
                title=task.title,
            )
            distance = origin.distance(centre) if origin is not None else 0.0
            candidates.append((region, distance))

    candidates.sort(key=lambda item: (item[1], item[0].identifier))
    return [region for region, _ in candidates[:limit]]


def differs(current: list[MonitoredRegion], wanted: list[MonitoredRegion]) -> bool:
    return {r.identifier for r in current} != {r.identifier for r in wanted}
