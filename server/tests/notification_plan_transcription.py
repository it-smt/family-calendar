"""A transcription of NotificationPlan.make, in the same shape as the Swift.

iOS keeps at most 64 pending notifications and drops the rest without saying
so. Which alerts survive that cut is therefore a correctness question, not a
tuning one, and it is worth testing somewhere a test can actually run.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from tests.recurrence_transcription import RecurrenceRule, expand
from tests.travel_transcription import leave_time

LIMIT = 50
HORIZON = timedelta(days=60)


@dataclass(frozen=True)
class Reminder:
    id: str
    task_id: str
    offset_minutes: int
    kind: str = "fixed"
    deleted: bool = False


@dataclass(frozen=True)
class Task:
    id: str
    title: str
    starts_at: datetime | None
    rrule: str | None = None
    exceptions: tuple[datetime, ...] = ()
    deleted: bool = False
    completed: bool = False


@dataclass(frozen=True)
class Planned:
    task_id: str
    reminder_id: str
    occurrence: datetime
    fire_at: datetime

    @property
    def identifier(self) -> str:
        return f"{self.task_id}|{self.reminder_id}|{int(self.occurrence.timestamp())}"


def occurrences(task: Task, window: tuple[datetime, datetime]) -> list[datetime]:
    if task.starts_at is None:
        return []
    rule = RecurrenceRule.parse(task.rrule)
    if rule is None:
        moments = [task.starts_at] if window[0] <= task.starts_at < window[1] else []
    else:
        moments = expand(rule, task.starts_at, window)
    return [moment for moment in moments if moment not in task.exceptions]


def make(
    tasks: list[Task],
    reminders: dict[str, list[Reminder]],
    now: datetime,
    estimates: dict | None = None,
    limit: int = LIMIT,
    horizon: timedelta = HORIZON,
) -> list[Planned]:
    estimates = estimates or {}
    window = (now, now + horizon)
    planned: list[Planned] = []

    for task in tasks:
        if task.deleted or task.completed:
            continue
        task_reminders = reminders.get(task.id) or []
        if not task_reminders:
            continue

        for occurrence in occurrences(task, window):
            for reminder in task_reminders:
                if reminder.deleted or reminder.kind == "geo":
                    continue
                # A "leave now" reminder counts back from the door, not from
                # the appointment. Without an estimate it behaves like an
                # ordinary reminder rather than going silent.
                estimate = estimates.get(task.id)
                if reminder.kind == "leave_time" and estimate is not None:
                    anchor = leave_time(occurrence, estimate)
                else:
                    anchor = occurrence

                fire_at = anchor + timedelta(minutes=reminder.offset_minutes)
                if fire_at <= now:
                    continue
                planned.append(Planned(task.id, reminder.id, occurrence, fire_at))

    planned.sort(key=lambda item: (item.fire_at, item.identifier))
    return planned[:limit]
