"""Tasks and the rows that hang off them.

Note on constraints: this schema deliberately stops at NOT NULL and foreign
keys. A CHECK the client can violate is worse here than a bad row — the device
has already committed the change locally and would retry the same rejected push
forever. Cross-field rules (a geo reminder needs coordinates, a latitude is
within range) belong on the device, before the row is written.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Enum,
    Float,
    Index,
    Integer,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, HouseholdScopedMixin, sync_fk
from app.db.enums import ReminderKind, TravelMode

travel_mode_enum = Enum(
    TravelMode,
    name="travel_mode",
    values_callable=lambda enum_cls: [member.value for member in enum_cls],
)
reminder_kind_enum = Enum(
    ReminderKind,
    name="reminder_kind",
    values_callable=lambda enum_cls: [member.value for member in enum_cls],
)


class Task(Base, HouseholdScopedMixin):
    __tablename__ = "tasks"

    title: Mapped[str] = mapped_column(Text, nullable=False)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    starts_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    duration_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    is_all_day: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text("false"))

    location_name: Mapped[str | None] = mapped_column(Text, nullable=True)
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)

    # RFC 5545 recurrence rule, stored verbatim and expanded on the device.
    rrule: Mapped[str | None] = mapped_column(Text, nullable=True)
    # ISO-8601 instants of cancelled or moved occurrences. JSON rather than
    # timestamptz[] so the value survives a round trip through change_log
    # payloads and into SQLite unchanged.
    recurrence_exceptions: Mapped[list] = mapped_column(
        JSONB, nullable=False, server_default=text("'[]'::jsonb")
    )

    assignee_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("users.id"), nullable=True
    )
    created_by: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("users.id"), nullable=False
    )
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("categories.id"), nullable=True
    )

    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    travel_mode: Mapped[TravelMode] = mapped_column(
        travel_mode_enum, nullable=False, server_default=TravelMode.NONE.value
    )

    __table_args__ = (
        # The day view and the widget both read a date window.
        Index("ix_tasks_household_id_starts_at", "household_id", "starts_at"),
        Index("ix_tasks_household_id_updated_at", "household_id", "updated_at"),
        Index("ix_tasks_assignee_id", "assignee_id"),
        Index("ix_tasks_category_id", "category_id"),
    )


class Reminder(Base, HouseholdScopedMixin):
    """One of several reminders on a task."""

    __tablename__ = "reminders"

    task_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("tasks.id"), nullable=False
    )
    # Negative means before the start of the task.
    offset_minutes: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    kind: Mapped[ReminderKind] = mapped_column(
        reminder_kind_enum, nullable=False, server_default=ReminderKind.FIXED.value
    )

    # Geofence, used when kind = geo.
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    radius_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    on_enter: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text("false"))
    on_exit: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text("false"))

    __table_args__ = (
        Index("ix_reminders_task_id", "task_id"),
        Index("ix_reminders_household_id_updated_at", "household_id", "updated_at"),
    )


class Subtask(Base, HouseholdScopedMixin):
    """A step of a task, and also a "what to bring" item."""

    __tablename__ = "subtasks"

    task_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("tasks.id"), nullable=False
    )
    title: Mapped[str] = mapped_column(Text, nullable=False)
    is_done: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text("false"))
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))

    __table_args__ = (
        Index("ix_subtasks_task_id_sort_order", "task_id", "sort_order"),
        Index("ix_subtasks_household_id_updated_at", "household_id", "updated_at"),
    )
