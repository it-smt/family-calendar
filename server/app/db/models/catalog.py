"""Categories, packing templates and the shopping list."""

from __future__ import annotations

import uuid

from sqlalchemy import Boolean, Index, String, Text, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, HouseholdScopedMixin, sync_fk


class Category(Base, HouseholdScopedMixin):
    __tablename__ = "categories"

    name: Mapped[str] = mapped_column(Text, nullable=False)
    color_hex: Mapped[str] = mapped_column(String(9), nullable=False, server_default="#8E8E93")
    icon: Mapped[str | None] = mapped_column(Text, nullable=True)

    __table_args__ = (Index("ix_categories_household_id_updated_at", "household_id", "updated_at"),)


class PackingTemplate(Base, HouseholdScopedMixin):
    """A named list of things to bring; applying it creates subtasks."""

    __tablename__ = "packing_templates"

    name: Mapped[str] = mapped_column(Text, nullable=False)
    # A JSON array of strings. The items have no identity of their own — the
    # template is edited as a whole, so last-write-wins applies to the list.
    items: Mapped[list] = mapped_column(JSONB, nullable=False, server_default=text("'[]'::jsonb"))

    __table_args__ = (
        Index("ix_packing_templates_household_id_updated_at", "household_id", "updated_at"),
    )


class ShoppingItem(Base, HouseholdScopedMixin):
    """An entity of its own, not a task."""

    __tablename__ = "shopping_items"

    title: Mapped[str] = mapped_column(Text, nullable=False)
    # Free text rather than a number: "2", "2 kg" and "a pack" are all typed
    # into the same field in practice.
    quantity: Mapped[str | None] = mapped_column(Text, nullable=True)
    is_bought: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text("false"))
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("categories.id"), nullable=True
    )
    added_by: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), sync_fk("users.id"), nullable=False
    )

    __table_args__ = (
        Index("ix_shopping_items_household_id_updated_at", "household_id", "updated_at"),
        Index("ix_shopping_items_category_id", "category_id"),
    )
