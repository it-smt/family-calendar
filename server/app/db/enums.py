"""Enumerations shared by the Postgres schema and the SQLite schema on device.

Values are stored as strings on both sides so a change row can be copied
between the two databases without translation.
"""

from __future__ import annotations

import enum


class TravelMode(enum.StrEnum):
    NONE = "none"
    WALKING = "walking"
    DRIVING = "driving"
    TRANSIT = "transit"


class ReminderKind(enum.StrEnum):
    FIXED = "fixed"
    LEAVE_TIME = "leave_time"
    GEO = "geo"
