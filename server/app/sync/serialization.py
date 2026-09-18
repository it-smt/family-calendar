"""The wire format.

A change payload has to survive the trip into SQLite unchanged, so values are
written in exactly the shape the device stores them: uppercase UUID strings and
RFC 3339 timestamps in UTC with milliseconds. See schema/PARITY.md.
"""

from __future__ import annotations

import enum
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Row


def to_wire(value: Any) -> Any:
    if isinstance(value, uuid.UUID):
        return str(value).upper()
    if isinstance(value, datetime):
        return timestamp(value)
    if isinstance(value, enum.Enum):
        return value.value
    return value


def timestamp(value: datetime) -> str:
    """RFC 3339, UTC, milliseconds — the one format both sides read and write."""
    return (
        value.astimezone(UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def row_to_payload(row: Row) -> dict[str, Any]:
    return {key: to_wire(value) for key, value in row._mapping.items()}
