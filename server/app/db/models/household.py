"""The shared space and the people in it."""

from __future__ import annotations

from sqlalchemy import Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, HouseholdScopedMixin, SyncMixin


class Household(Base, SyncMixin):
    """The family's shared space. Its own id is the household id."""

    __tablename__ = "households"

    name: Mapped[str] = mapped_column(Text, nullable=False)
    invite_code: Mapped[str] = mapped_column(String(16), nullable=False)

    __table_args__ = (
        # Tombstoned households release their code back for reuse.
        Index(
            "uq_households_invite_code_live",
            "invite_code",
            unique=True,
            postgresql_where="deleted_at IS NULL",
        ),
    )


class User(Base, HouseholdScopedMixin):
    """A member of the household. Two of them, in practice."""

    __tablename__ = "users"

    display_name: Mapped[str] = mapped_column(Text, nullable=False)
    color: Mapped[str] = mapped_column(String(9), nullable=False, server_default="#3478F6")

    __table_args__ = (Index("ix_users_household_id_updated_at", "household_id", "updated_at"),)
