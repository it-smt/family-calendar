"""occurrence completions

A repeat is one row and a rule, so there was nowhere to record that this
Tuesday is done. Ticking one off struck it out of the rule instead: the line
vanished rather than going grey, and "skipped" and "done" became the same
thing.

Revision ID: 0004
Revises: 0003
Create Date: 2026-09-19 10:40:00.000000
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "occurrence_completions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("household_id", sa.UUID(), nullable=False),
        sa.Column("task_id", sa.UUID(), nullable=False),
        sa.Column("occurrence", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_by", sa.UUID(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("updated_by", sa.UUID(), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["household_id"],
            ["households.id"],
            name=op.f("fk_occurrence_completions_household_id_households"),
            deferrable=True,
            initially="DEFERRED",
        ),
        sa.ForeignKeyConstraint(
            ["task_id"],
            ["tasks.id"],
            name=op.f("fk_occurrence_completions_task_id_tasks"),
            deferrable=True,
            initially="DEFERRED",
        ),
        sa.ForeignKeyConstraint(
            ["completed_by"],
            ["users.id"],
            name=op.f("fk_occurrence_completions_completed_by_users"),
            deferrable=True,
            initially="DEFERRED",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_occurrence_completions")),
    )
    # Deliberately not unique on (task_id, occurrence): two phones ticking the
    # same Tuesday offline would each make a row, and a constraint the device
    # can violate is worse than a duplicate — the push would be rejected for
    # ever by a device that has already committed the change.
    op.create_index(
        "ix_occurrence_completions_task_id_occurrence",
        "occurrence_completions",
        ["task_id", "occurrence"],
    )
    op.create_index(
        "ix_occurrence_completions_household_id_updated_at",
        "occurrence_completions",
        ["household_id", "updated_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_occurrence_completions_household_id_updated_at",
        table_name="occurrence_completions",
    )
    op.drop_index(
        "ix_occurrence_completions_task_id_occurrence",
        table_name="occurrence_completions",
    )
    op.drop_table("occurrence_completions")
