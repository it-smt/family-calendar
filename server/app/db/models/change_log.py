"""The pull cursor lives here.

The cursor is `seq`, not a timestamp: device clocks drift, and a row written
with a slightly late clock would be skipped forever by a time-based cursor.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, DateTime, Index, Text, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ChangeLog(Base):
    __tablename__ = "change_log"

    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    household_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    entity_type: Mapped[str] = mapped_column(Text, nullable=False)
    entity_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    # A full snapshot of the row, not a delta: last-write-wins replaces the
    # whole record anyway, and a snapshot lets a month-old device catch up in
    # one pass.
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )

    __table_args__ = (Index("ix_change_log_household_id_seq", "household_id", "seq"),)
