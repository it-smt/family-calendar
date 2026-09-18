"""Login credentials.

Deliberately not part of the synchronised schema. The `users` table travels to
both devices, so an email and a password hash stored there would be copied onto
every phone in the household and into every change payload. These stay here.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, Index, Text, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sync_fk


class Credential(Base):
    __tablename__ = "credentials"

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("users.id"), primary_key=True
    )
    #: Stored lowercased; the unique index is what makes the address an identity.
    email: Mapped[str] = mapped_column(Text, nullable=False)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )

    __table_args__ = (Index("uq_credentials_email", "email", unique=True),)
