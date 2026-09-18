"""When the widget redraws itself.

A widget that misses a moment is wrong for hours and says nothing about it, so
these pin down the moments: the present, every time an event starts or ends, and
the turn of the day.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from tests.widget_timeline_transcription import (
    MAXIMUM_ENTRIES,
    points,
    reload_after,
)

NOW = datetime(2026, 9, 18, 9, 0, tzinfo=UTC)
END_OF_DAY = datetime(2026, 9, 19, 0, 0, tzinfo=UTC)


def at(hour: float) -> datetime:
    return NOW.replace(hour=0, minute=0) + timedelta(hours=hour)


def test_the_first_entry_is_always_now():
    """WidgetKit shows the first entry immediately; a later one leaves a gap."""
    chosen = points([at(14)], [at(15)], now=NOW, end_of_day=END_OF_DAY)

    assert chosen[0] == NOW


def test_every_start_and_end_becomes_a_moment():
    """Each one changes what "next" means."""
    chosen = points([at(11), at(14)], [at(12), at(15)], now=NOW, end_of_day=END_OF_DAY)

    assert chosen == [NOW, at(11), at(12), at(14), at(15), END_OF_DAY]


def test_things_already_past_are_not_moments():
    chosen = points([at(7), at(14)], [at(8)], now=NOW, end_of_day=END_OF_DAY)

    assert at(7) not in chosen
    assert at(8) not in chosen
    assert at(14) in chosen


def test_the_day_turns_over_on_its_own():
    """Otherwise a finished today sits there until someone opens the app."""
    chosen = points([], [], now=NOW, end_of_day=END_OF_DAY)

    assert chosen == [NOW, END_OF_DAY]


def test_moments_are_unique_and_in_order():
    """An event ending exactly as another starts is one moment, not two."""
    chosen = points([at(12), at(12)], [at(12)], now=NOW, end_of_day=END_OF_DAY)

    assert chosen == [NOW, at(12), END_OF_DAY]
    assert chosen == sorted(chosen)


def test_a_crowded_day_keeps_the_nearest_moments():
    """Right for the next few hours and then asking again beats the reverse."""
    starts = [NOW + timedelta(minutes=10 * index) for index in range(1, 60)]
    chosen = points(starts, [], now=NOW, end_of_day=END_OF_DAY)

    assert len(chosen) == MAXIMUM_ENTRIES
    assert chosen[0] == NOW
    assert chosen == sorted(chosen)
    assert chosen[-1] == starts[MAXIMUM_ENTRIES - 2]


def test_the_reload_is_never_asked_for_in_the_past():
    assert reload_after([], now=NOW) == NOW + timedelta(hours=1)
    assert reload_after([NOW - timedelta(hours=3)], now=NOW) == NOW + timedelta(hours=1)


def test_an_empty_day_still_comes_back_within_the_hour():
    """A widget that goes quiet for a whole day is a widget nobody trusts."""
    chosen = points([], [], now=NOW, end_of_day=NOW + timedelta(minutes=20))

    assert reload_after(chosen, now=NOW) == NOW + timedelta(hours=1)
