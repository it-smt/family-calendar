"""A transcription of Travel and GeoPoint, in the same shape as the Swift.

Deciding when someone has to leave is the feature the spec calls the point of
the application, and most of it is arithmetic that has to be right whether or
not there is a network. That part is kept here too so it can be tested.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta

CELL_SIZE = 0.005
DEPARTURE_BUFFER = timedelta(minutes=5)
DETOUR_FACTOR = 1.4
EARTH_RADIUS = 6_371_000.0


@dataclass(frozen=True)
class GeoPoint:
    latitude: float
    longitude: float

    def distance(self, other: GeoPoint) -> float:
        phi1 = math.radians(self.latitude)
        phi2 = math.radians(other.latitude)
        delta_phi = math.radians(other.latitude - self.latitude)
        delta_lambda = math.radians(other.longitude - self.longitude)

        a = (
            math.sin(delta_phi / 2) ** 2
            + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2
        )
        return 2 * EARTH_RADIUS * math.atan2(math.sqrt(a), math.sqrt(1 - a))

    def cell(self, precision: float = CELL_SIZE) -> str:
        return f"{round(self.latitude / precision)}:{round(self.longitude / precision)}"


@dataclass(frozen=True)
class TravelEstimate:
    duration: float
    distance: float
    source: str
    measured_at: datetime

    @property
    def is_approximate(self) -> bool:
        return self.source in {"stale", "estimated"}


def freshness(mode: str, with_traffic: bool) -> timedelta:
    if mode == "none":
        return timedelta(0)
    if mode == "walking":
        return timedelta(hours=24)
    if mode == "driving":
        return timedelta(minutes=15) if with_traffic else timedelta(hours=1)
    return timedelta(minutes=30)


def typical_speed(mode: str) -> float:
    return {
        "none": 0.0,
        "walking": 5_000 / 3_600,
        "driving": 25_000 / 3_600,
        "transit": 18_000 / 3_600,
    }[mode]


def fallback(origin: GeoPoint, destination: GeoPoint, mode: str, now: datetime):
    if mode == "none":
        return None
    travelled = origin.distance(destination) * DETOUR_FACTOR
    speed = typical_speed(mode)
    if speed <= 0:
        return None
    return TravelEstimate(travelled / speed, travelled, "estimated", now)


def offline_estimate(cached, origin: GeoPoint, destination: GeoPoint, mode: str, now: datetime):
    if cached is not None:
        age = now - cached["measured_at"]
        limit = freshness(mode, cached["with_traffic"])
        return TravelEstimate(
            cached["duration"],
            cached["distance"],
            "cached" if age <= limit else "stale",
            cached["measured_at"],
        )
    return fallback(origin, destination, mode, now)


def leave_time(start: datetime, estimate: TravelEstimate) -> datetime:
    return start - timedelta(seconds=estimate.duration) - DEPARTURE_BUFFER


def needs_refresh(measured_at: datetime | None, mode: str, with_traffic: bool, now: datetime) -> bool:
    if measured_at is None:
        return True
    return (now - measured_at) > freshness(mode, with_traffic)
