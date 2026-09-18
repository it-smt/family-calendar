"""Push tokens.

Deliberately not `users.apns_token`, which is where the model first put it.

A token belongs to a device, not to a person: one person can have a phone and a
tablet, and each needs waking separately. Worse, `users` is a synchronised row,
and last-write-wins compares whole rows — so the partner's phone, editing a
display name from a copy it fetched an hour ago, would push back the token it
had then and silently unregister a device it knows nothing about. A value only
one device can know has no business travelling through a shared row.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, Index, Text, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sync_fk


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("users.id"), nullable=False
    )
    #: The APNs device token, hex as Apple hands it over.
    token: Mapped[str] = mapped_column(Text, nullable=False)
    platform: Mapped[str] = mapped_column(Text, nullable=False, server_default="ios")

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    #: Cleared when APNs says the token is gone, so a dead device stops being
    #: woken and stops costing a request every time anything changes.
    unregistered_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    __table_args__ = (
        Index("uq_devices_token", "token", unique=True),
        Index("ix_devices_user_id", "user_id"),
    )
