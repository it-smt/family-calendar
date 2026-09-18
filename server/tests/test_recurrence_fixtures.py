"""The recurrence fixtures say what RFC 5545 says.

The device expands a repeating task into concrete instants before it can
schedule a notification for one. That expansion is the only real algorithm in
the client, and there is no Swift toolchain here to run it against.

So the cases live in a JSON file that both sides read. Here they are checked
against python-dateutil, a mature RFC 5545 implementation, which makes the
expected values the standard's answers rather than this project's opinion of
them. `RecurrenceTests.swift` reads the same file, so the Swift expander is
measured against the same standard without either end being trusted.
"""

from __future__ import annotations

import json
import pathlib
from datetime import datetime

import pytest
from dateutil.rrule import rrulestr

FIXTURES = (
    pathlib.Path(__file__).resolve().parents[2]
    / "ios/FamilyCalendarKit/Tests/FamilyCalendarKitTests/Fixtures/recurrence.json"
)

CASES = json.loads(FIXTURES.read_text())["cases"]


def parse(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def wire(moment: datetime) -> str:
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def expand(case: dict) -> list[str]:
    """What RFC 5545 says this case expands to."""
    if case["starts_at"] is None:
        return []

    start = parse(case["starts_at"])
    window_start, window_end = (parse(value) for value in case["window"])
    exceptions = {parse(value) for value in case.get("exceptions", [])}

    if case["rrule"] is None:
        occurrences = [start] if window_start <= start < window_end else []
    else:
        rule = rrulestr(case["rrule"], dtstart=start)
        # `between` is exclusive at both ends, so ask for the closed interval
        # and filter to the half-open one the client uses.
        occurrences = [
            moment
            for moment in rule.between(window_start, window_end, inc=True)
            if window_start <= moment < window_end
        ]

    return [wire(moment) for moment in occurrences if moment not in exceptions]


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_the_fixture_matches_the_standard(case):
    assert expand(case) == case["expected"]


def test_the_fixtures_cover_what_a_family_calendar_uses():
    rules = [case["rrule"] or "" for case in CASES]
    for fragment in ("FREQ=DAILY", "FREQ=WEEKLY", "FREQ=MONTHLY", "FREQ=YEARLY",
                     "INTERVAL=", "COUNT=", "UNTIL=", "BYDAY=", "BYMONTHDAY="):
        assert any(fragment in rule for rule in rules), f"no case uses {fragment}"
    assert any("exceptions" in case for case in CASES)
