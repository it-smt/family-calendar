"""The transcribed algorithm against python-dateutil, on rules nobody chose.

The fixtures were written by hand, so they test the cases someone thought of.
This generates rules and windows at random and compares the expansion with a
mature RFC 5545 implementation, which is how the cases nobody thought of get
found.
"""

from __future__ import annotations

import random
from datetime import UTC, datetime, timedelta

import pytest
from dateutil.rrule import rrulestr

from tests.recurrence_transcription import RecurrenceRule, expand

WEEKDAY_NAMES = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]


def random_rule(rng: random.Random) -> str:
    frequency = rng.choice(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])
    parts = [f"FREQ={frequency}"]

    if rng.random() < 0.5:
        parts.append(f"INTERVAL={rng.randint(1, 4)}")
    if frequency == "WEEKLY" and rng.random() < 0.6:
        days = rng.sample(WEEKDAY_NAMES, rng.randint(1, 3))
        parts.append(f"BYDAY={','.join(days)}")
    if frequency == "MONTHLY" and rng.random() < 0.6:
        parts.append(f"BYMONTHDAY={rng.choice([1, 5, 15, 28, 29, 30, 31])}")

    # COUNT and UNTIL are mutually exclusive in the standard.
    if rng.random() < 0.3:
        parts.append(f"COUNT={rng.randint(1, 12)}")
    elif rng.random() < 0.3:
        until = datetime(2026, 1, 1, tzinfo=UTC) + timedelta(days=rng.randint(1, 900))
        parts.append(f"UNTIL={until.strftime('%Y%m%dT%H%M%SZ')}")

    return ";".join(parts)


def reference(rule_text: str, start: datetime, window: tuple[datetime, datetime]) -> list[datetime]:
    rule = rrulestr(rule_text, dtstart=start)
    return [
        moment
        for moment in rule.between(window[0], window[1], inc=True)
        if window[0] <= moment < window[1]
    ]


@pytest.mark.parametrize("seed", range(400))
def test_random_rules_expand_the_way_the_standard_says(seed):
    rng = random.Random(seed)

    start = datetime(2026, 1, 1, tzinfo=UTC) + timedelta(
        days=rng.randint(0, 720), hours=rng.randint(0, 23), minutes=rng.choice([0, 15, 30, 45])
    )
    window_start = start + timedelta(days=rng.randint(-400, 400))
    window = (window_start, window_start + timedelta(days=rng.randint(1, 500)))

    rule_text = random_rule(rng)
    rule = RecurrenceRule.parse(rule_text)
    assert rule is not None, rule_text

    mine = expand(rule, start, window)
    theirs = reference(rule_text, start, window)

    assert mine == theirs, f"{rule_text} from {start.isoformat()} over {window}"
