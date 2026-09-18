"""A line-by-line transcription of Recurrence.expand from the Swift.

Not a second implementation with its own ideas — a transcription, kept in the
same shape as `Recurrence/RecurrenceRule.swift`, so that running it against the
fixtures tests the *algorithm* rather than the language. Swift syntax and GRDB
APIs are Xcode's job; whether the loop produces the right instants is this
file's.

If the Swift changes, this changes with it, or `test_recurrence_transcription`
stops meaning anything.
"""

from __future__ import annotations

import calendar as calendar_module
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

MAXIMUM_PERIODS = 20_000
WEEKDAYS = {"SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7}
FIRST_WEEKDAY = 2  # Monday, which is WKST=MO


@dataclass
class RecurrenceRule:
    frequency: str
    interval: int = 1
    count: int | None = None
    until: datetime | None = None
    by_weekday: list[int] = field(default_factory=list)
    by_month_day: list[int] = field(default_factory=list)

    @classmethod
    def parse(cls, text: str | None) -> RecurrenceRule | None:
        if not text:
            return None
        parts = {}
        for component in text.upper().split(";"):
            key, _, value = component.partition("=")
            if value:
                parts[key] = value
        if parts.get("FREQ") not in {"DAILY", "WEEKLY", "MONTHLY", "YEARLY"}:
            return None
        return cls(
            frequency=parts["FREQ"],
            interval=max(1, int(parts.get("INTERVAL", 1))),
            count=int(parts["COUNT"]) if "COUNT" in parts else None,
            until=parse_until(parts["UNTIL"]) if "UNTIL" in parts else None,
            by_weekday=[WEEKDAYS[day[-2:]] for day in parts.get("BYDAY", "").split(",") if day],
            by_month_day=[int(day) for day in parts.get("BYMONTHDAY", "").split(",") if day],
        )


def parse_until(value: str) -> datetime | None:
    for fmt in ("%Y%m%dT%H%M%SZ", "%Y%m%dT%H%M%S", "%Y%m%d"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def gregorian_weekday(moment: datetime) -> int:
    """Sunday = 1, matching Foundation's `Calendar`."""
    return (moment.weekday() + 1) % 7 + 1


def sort_key(weekday: int) -> int:
    return (weekday - FIRST_WEEKDAY + 7) % 7


def week_start(moment: datetime) -> datetime:
    start_of_day = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    return start_of_day - timedelta(days=sort_key(gregorian_weekday(moment)))


def add_months(moment: datetime, months: int) -> datetime:
    total = moment.month - 1 + months
    year = moment.year + total // 12
    month = total % 12 + 1
    day = min(moment.day, calendar_module.monthrange(year, month)[1])
    return moment.replace(year=year, month=month, day=day)


def at_time(day: datetime, time_source: datetime) -> datetime:
    return day.replace(
        hour=time_source.hour,
        minute=time_source.minute,
        second=time_source.second,
        microsecond=time_source.microsecond,
    )


def period_start(rule: RecurrenceRule, period: int, start: datetime) -> datetime:
    step = period * rule.interval
    if rule.frequency == "DAILY":
        return start + timedelta(days=step)
    if rule.frequency == "WEEKLY":
        return start + timedelta(weeks=step)
    if rule.frequency == "MONTHLY":
        return add_months(start, step)
    return start.replace(year=start.year + step)


def candidates(rule: RecurrenceRule, period: int, start: datetime) -> list[datetime]:
    step = period * rule.interval

    if rule.frequency == "DAILY":
        return [start + timedelta(days=step)]

    if rule.frequency == "WEEKLY":
        anchor = week_start(start) + timedelta(weeks=step)
        weekdays = rule.by_weekday or [gregorian_weekday(start)]
        return [
            at_time(anchor + timedelta(days=sort_key(weekday)), start)
            for weekday in sorted(weekdays, key=sort_key)
        ]

    if rule.frequency == "MONTHLY":
        month_anchor = add_months(start.replace(day=1), step)
        days = sorted(rule.by_month_day) or [start.day]
        available = calendar_module.monthrange(month_anchor.year, month_anchor.month)[1]
        return [
            at_time(month_anchor.replace(day=day), start)
            for day in days
            if 1 <= day <= available
        ]

    # YEARLY: 29 February is not 1 March.
    year = start.year + step
    try:
        return [at_time(start.replace(year=year), start)]
    except ValueError:
        return []


def is_exhausted(rule: RecurrenceRule, period: int, start: datetime, window_end: datetime) -> bool:
    anchor = period_start(rule, period, start)
    if rule.until is not None and anchor > rule.until:
        return True
    return anchor >= window_end


def expand(rule: RecurrenceRule, start: datetime, window: tuple[datetime, datetime]) -> list[datetime]:
    window_start, window_end = window
    found: list[datetime] = []
    produced = 0

    for period in range(MAXIMUM_PERIODS):
        moments = candidates(rule, period, start)
        if not moments:
            if is_exhausted(rule, period, start, window_end):
                break
            continue

        for candidate in moments:
            if candidate < start:
                continue
            if rule.until is not None and candidate > rule.until:
                return found
            if rule.count is not None and produced >= rule.count:
                return found
            produced += 1

            if window_start <= candidate < window_end:
                found.append(candidate)
            elif candidate >= window_end:
                return found

        if moments[-1] >= window_end:
            break

    return found


def occurrences(case: dict) -> list[datetime]:
    """The entry point, mirroring `Recurrence.occurrences(of:in:)`."""
    if case["starts_at"] is None:
        return []

    start = datetime.fromisoformat(case["starts_at"].replace("Z", "+00:00"))
    window = tuple(
        datetime.fromisoformat(value.replace("Z", "+00:00")) for value in case["window"]
    )
    exceptions = {
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        for value in case.get("exceptions", [])
    }

    rule = RecurrenceRule.parse(case["rrule"])
    if rule is None:
        moments = [start] if window[0] <= start < window[1] else []
    else:
        moments = expand(rule, start, window)

    return [moment for moment in moments if moment not in exceptions]
