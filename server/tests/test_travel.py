"""Working out when to leave.

The arithmetic behind the feature the spec calls the point of the application.
It has to produce an answer with no network, and the answer has to be wrong in
the safe direction when it is wrong at all.
"""

from __future__ import annotations

import math
import random
from datetime import UTC, datetime, timedelta

import pytest

from tests.travel_transcription import (
    CELL_SIZE,
    DEPARTURE_BUFFER,
    GeoPoint,
    fallback,
    leave_time,
    needs_refresh,
    offline_estimate,
    typical_speed,
)

NOW = datetime(2026, 9, 18, 9, 0, tzinfo=UTC)

HOME = GeoPoint(55.751244, 37.618423)   # Red Square
CLINIC = GeoPoint(55.760000, 37.640000)


# --- distance --------------------------------------------------------------

def spherical_law_of_cosines(a: GeoPoint, b: GeoPoint) -> float:
    """An independent formula, for checking the one in the source."""
    phi1, phi2 = math.radians(a.latitude), math.radians(b.latitude)
    delta = math.radians(b.longitude - a.longitude)
    return math.acos(
        min(1.0, math.sin(phi1) * math.sin(phi2) + math.cos(phi1) * math.cos(phi2) * math.cos(delta))
    ) * 6_371_000.0


def test_a_point_is_no_distance_from_itself():
    assert HOME.distance(HOME) == pytest.approx(0, abs=1e-6)


def test_one_degree_of_latitude_is_about_111_kilometres():
    a = GeoPoint(55.0, 37.0)
    b = GeoPoint(56.0, 37.0)

    assert a.distance(b) == pytest.approx(111_195, rel=0.001)


def test_a_known_long_distance():
    """Moscow to Saint Petersburg, about 634 km as the crow flies."""
    moscow = GeoPoint(55.7539, 37.6208)
    saint_petersburg = GeoPoint(59.9398, 30.3146)

    assert moscow.distance(saint_petersburg) == pytest.approx(634_000, rel=0.01)


def test_distance_is_symmetric():
    assert HOME.distance(CLINIC) == pytest.approx(CLINIC.distance(HOME), abs=1e-6)


@pytest.mark.parametrize("seed", range(100))
def test_the_formula_agrees_with_an_independent_one(seed):
    rng = random.Random(seed)
    a = GeoPoint(rng.uniform(-70, 70), rng.uniform(-180, 180))
    b = GeoPoint(rng.uniform(-70, 70), rng.uniform(-180, 180))

    assert a.distance(b) == pytest.approx(spherical_law_of_cosines(a, b), rel=1e-6, abs=1.0)


# --- cache cells -----------------------------------------------------------

def test_the_same_point_always_lands_in_the_same_cell():
    assert HOME.cell() == GeoPoint(HOME.latitude, HOME.longitude).cell()


def test_a_cell_is_small_enough_to_still_be_about_the_same_journey():
    """Two points that share a cell are close enough to reuse a route."""
    rng = random.Random(7)
    for _ in range(500):
        base = GeoPoint(rng.uniform(-60, 60), rng.uniform(-180, 179))
        nearby = GeoPoint(
            base.latitude + rng.uniform(-CELL_SIZE, CELL_SIZE),
            base.longitude + rng.uniform(-CELL_SIZE, CELL_SIZE),
        )
        if base.cell() == nearby.cell():
            assert base.distance(nearby) < 900


def test_somewhere_across_town_is_a_different_cell():
    across_town = GeoPoint(HOME.latitude + 0.05, HOME.longitude + 0.05)

    assert HOME.cell() != across_town.cell()


# --- the fallback ----------------------------------------------------------

def test_with_nothing_measured_the_answer_is_geometry():
    estimate = fallback(HOME, CLINIC, "walking", NOW)

    straight_line = HOME.distance(CLINIC)
    assert estimate.source == "estimated"
    assert estimate.distance == pytest.approx(straight_line * 1.4)
    assert estimate.duration == pytest.approx(straight_line * 1.4 / typical_speed("walking"))
    assert estimate.is_approximate


def test_the_fallback_leans_towards_leaving_early():
    """Leaving early is an inconvenience. Leaving late is the failure."""
    straight_line = HOME.distance(CLINIC)

    for mode in ("walking", "driving", "transit"):
        estimate = fallback(HOME, CLINIC, mode, NOW)
        # The bent distance is never shorter than the straight line, and the
        # speeds are below what the mode actually manages.
        assert estimate.distance > straight_line
        assert estimate.duration > straight_line / typical_speed(mode)


def test_driving_beats_walking_and_the_bus_sits_between():
    walking = fallback(HOME, CLINIC, "walking", NOW).duration
    driving = fallback(HOME, CLINIC, "driving", NOW).duration
    transit = fallback(HOME, CLINIC, "transit", NOW).duration

    assert driving < transit < walking


def test_a_task_with_no_travel_has_no_estimate():
    assert fallback(HOME, CLINIC, "none", NOW) is None


# --- choosing an answer offline -------------------------------------------

def cached(minutes_ago: int, with_traffic: bool = True, duration: float = 1500):
    return {
        "duration": duration,
        "distance": 8000,
        "with_traffic": with_traffic,
        "measured_at": NOW - timedelta(minutes=minutes_ago),
    }


def test_a_fresh_measurement_is_used_as_it_is():
    estimate = offline_estimate(cached(5), HOME, CLINIC, "driving", NOW)

    assert estimate.source == "cached"
    assert estimate.duration == 1500
    assert not estimate.is_approximate


def test_a_stale_measurement_still_beats_a_straight_line():
    """The traffic has moved on, but the road has not."""
    estimate = offline_estimate(cached(90), HOME, CLINIC, "driving", NOW)

    assert estimate.source == "stale"
    assert estimate.duration == 1500
    assert estimate.is_approximate


def test_walking_measurements_stay_good_for_a_day():
    """Pavements do not get congested."""
    assert offline_estimate(cached(600, with_traffic=False), HOME, CLINIC, "walking", NOW).source == "cached"


def test_a_driving_measurement_with_traffic_goes_off_quickly():
    assert offline_estimate(cached(10), HOME, CLINIC, "driving", NOW).source == "cached"
    assert offline_estimate(cached(20), HOME, CLINIC, "driving", NOW).source == "stale"


def test_with_nothing_cached_geometry_is_the_floor():
    estimate = offline_estimate(None, HOME, CLINIC, "driving", NOW)

    assert estimate.source == "estimated"


# --- when to leave ---------------------------------------------------------

def test_leaving_accounts_for_the_journey_and_a_little_slack():
    start = NOW + timedelta(hours=2)
    estimate = offline_estimate(cached(1, duration=25 * 60), HOME, CLINIC, "driving", NOW)

    assert leave_time(start, estimate) == start - timedelta(minutes=25) - DEPARTURE_BUFFER


def test_a_longer_journey_means_leaving_earlier():
    start = NOW + timedelta(hours=2)
    near = offline_estimate(cached(1, duration=10 * 60), HOME, CLINIC, "driving", NOW)
    far = offline_estimate(cached(1, duration=40 * 60), HOME, CLINIC, "driving", NOW)

    assert leave_time(start, far) < leave_time(start, near)


# --- when to measure again -------------------------------------------------

def test_never_measured_means_measure_now():
    assert needs_refresh(None, "driving", True, NOW)


def test_a_recent_measurement_is_not_repeated():
    """Asking MapKit again costs battery and, on a train, data."""
    assert not needs_refresh(NOW - timedelta(minutes=5), "driving", True, NOW)


def test_an_old_measurement_is_repeated():
    assert needs_refresh(NOW - timedelta(minutes=30), "driving", True, NOW)


def test_how_long_a_measurement_lasts_depends_on_the_mode():
    hour_ago = NOW - timedelta(hours=1)

    assert needs_refresh(hour_ago, "driving", True, NOW)
    assert needs_refresh(hour_ago, "transit", False, NOW)
    assert not needs_refresh(hour_ago, "walking", False, NOW)
