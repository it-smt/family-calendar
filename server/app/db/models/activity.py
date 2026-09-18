"""The change feed, so data never changes silently."""

from __future__ import annotations

import uuid

from sqlalchemy import Index, Text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, HouseholdScopedMixin, sync_fk


class ActivityEntry(Base, HouseholdScopedMixin):
    """Written on the server during push, handed back on pull.

    Append-only in practice: it carries the shared sync columns so it travels
    the same path as everything else, but nothing edits an entry after the fact.
    """

    __tablename__ = "activity_entries"

    actor_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("users.id"), nullable=False
    )
    entity_type: Mapped[str] = mapped_column(Text, nullable=False)
    entity_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    action: Mapped[str] = mapped_column(Text, nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)

    __table_args__ = (
        Index("ix_activity_entries_household_id_created_at", "household_id", "created_at"),
        Index("ix_activity_entries_entity_type_entity_id", "entity_type", "entity_id"),
    )
