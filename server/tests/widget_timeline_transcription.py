"""A transcription of WidgetTimeline.points, in the same shape as the Swift.

WidgetKit asks for entries in advance and then leaves the widget alone. A moment
the timeline forgot is a widget showing yesterday's next event through lunch, and
nothing reports it. Which moments are chosen is therefore worth testing where a
test can run.
"""

from __future__ import annotations

from datetime import datetime, timedelta

MAXIMUM_ENTRIES = 24


def points(
    task_starts: list[datetime],
    task_ends: list[datetime],
    now: datetime,
    end_of_day: datetime,
    limit: int = MAXIMUM_ENTRIES,
) -> list[datetime]:
    moments = {now}

    for moment in task_starts + task_ends:
        if now < moment < end_of_day:
            moments.add(moment)

    if end_of_day > now:
        moments.add(end_of_day)

    ordered = sorted(moments)
    if len(ordered) <= limit:
        return ordered
    return ordered[:limit]


def reload_after(chosen: list[datetime], now: datetime) -> datetime:
    return max(chosen[-1] if chosen else now, now + timedelta(hours=1))
