"""Schema tests.

Stage 1 has no logic, so these check the only things a schema can get wrong:
that the migration and the models agree, that it survives a full down/up cycle,
that every synchronised table carries the shared columns, and that the
constraints do not stand in the way of an offline-first push.
"""

from __future__ import annotations

import uuid

import pytest
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy import inspect, text

from app.db.models import Base

SYNC_COLUMNS = {"id", "household_id", "created_at", "updated_at", "updated_by", "deleted_at"}

SYNCED_TABLES = [
    "users",
    "categories",
    "packing_templates",
    "tasks",
    "reminders",
    "subtasks",
    "shopping_items",
    "activity_entries",
]


async def test_migration_matches_models(migrated_db):
    """The migration produces exactly the schema the models describe."""

    def diff(connection):
        context = MigrationContext.configure(
            connection, opts={"compare_type": True, "compare_server_default": True}
        )
        return compare_metadata(context, Base.metadata)

    assert await migrated_db.run_sync(diff) == []


async def test_every_synced_table_has_the_shared_columns(migrated_db):
    def columns(connection):
        inspector = inspect(connection)
        return {
            table: {column["name"] for column in inspector.get_columns(table)}
            for table in SYNCED_TABLES
        }

    by_table = await migrated_db.run_sync(columns)
    for table, names in by_table.items():
        assert SYNC_COLUMNS <= names, f"{table} is missing {SYNC_COLUMNS - names}"
        # `dirty` is an outbox flag on the device. The server never sees it.
        assert "dirty" not in names


async def test_households_carry_sync_columns_but_no_household_id(migrated_db):
    def columns(connection):
        return {column["name"] for column in inspect(connection).get_columns("households")}

    names = await migrated_db.run_sync(columns)
    assert SYNC_COLUMNS - {"household_id"} <= names
    # A household is the scope, so it does not point at one.
    assert "household_id" not in names


async def test_change_log_seq_is_server_assigned_and_monotonic(migrated_db):
    household_id = uuid.uuid4()
    seqs = []
    for _ in range(3):
        result = await migrated_db.execute(
            text(
                "INSERT INTO change_log (household_id, entity_type, entity_id, payload) "
                "VALUES (:h, 'task', :e, '{}'::jsonb) RETURNING seq"
            ),
            {"h": household_id, "e": uuid.uuid4()},
        )
        seqs.append(result.scalar_one())
    assert seqs == sorted(seqs)
    assert len(set(seqs)) == 3


async def test_foreign_keys_are_deferrable(migrated_db):
    """A push batch arrives unordered; the checks have to wait for COMMIT."""

    def constraints(connection):
        return connection.execute(
            text(
                "SELECT conname, condeferrable, condeferred FROM pg_constraint "
                "WHERE contype = 'f' AND connamespace = 'public'::regnamespace"
            )
        ).all()

    rows = await migrated_db.run_sync(constraints)
    assert rows, "expected foreign keys to exist"
    not_deferred = [name for name, deferrable, deferred in rows if not (deferrable and deferred)]
    assert not_deferred == []


async def test_a_task_can_be_inserted_before_the_category_it_points_at(migrated_db):
    """The practical consequence of the deferred checks."""
    household_id, user_id = uuid.uuid4(), uuid.uuid4()
    category_id, task_id = uuid.uuid4(), uuid.uuid4()

    await migrated_db.execute(
        text("INSERT INTO households (id, name, invite_code) VALUES (:i, 'Home', 'ABC123')"),
        {"i": household_id},
    )
    await migrated_db.execute(
        text(
            "INSERT INTO users (id, household_id, display_name) VALUES (:i, :h, 'Me')"
        ),
        {"i": user_id, "h": household_id},
    )
    # Task first, category second — the order a client outbox might produce.
    await migrated_db.execute(
        text(
            "INSERT INTO tasks (id, household_id, title, created_by, category_id) "
            "VALUES (:i, :h, 'Pool', :u, :c)"
        ),
        {"i": task_id, "h": household_id, "u": user_id, "c": category_id},
    )
    await migrated_db.execute(
        text("INSERT INTO categories (id, household_id, name) VALUES (:i, :h, 'Kids')"),
        {"i": category_id, "h": household_id},
    )
    await migrated_db.commit()

    count = await migrated_db.scalar(text("SELECT count(*) FROM tasks WHERE id = :i"), {"i": task_id})
    assert count == 1


async def test_no_foreign_key_deletes_rows(migrated_db):
    """Soft deletes only: nothing may cascade."""

    def rules(connection):
        return connection.execute(
            text(
                "SELECT conname, confdeltype::text FROM pg_constraint "
                "WHERE contype = 'f' AND connamespace = 'public'::regnamespace"
            )
        ).all()

    rows = await migrated_db.run_sync(rules)
    # 'a' is NO ACTION, the default.
    assert [name for name, delete_rule in rows if delete_rule != "a"] == []


async def test_invite_code_is_unique_among_live_households(migrated_db):
    first, second, third = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await migrated_db.execute(
        text("INSERT INTO households (id, name, invite_code) VALUES (:i, 'A', 'SAME01')"),
        {"i": first},
    )
    with pytest.raises(Exception):
        await migrated_db.execute(
            text("INSERT INTO households (id, name, invite_code) VALUES (:i, 'B', 'SAME01')"),
            {"i": second},
        )
    await migrated_db.rollback()

    # Tombstoning the first one frees the code again.
    await migrated_db.execute(
        text("INSERT INTO households (id, name, invite_code, deleted_at) VALUES (:i, 'A', 'SAME02', now())"),
        {"i": first},
    )
    await migrated_db.execute(
        text("INSERT INTO households (id, name, invite_code) VALUES (:i, 'B', 'SAME02')"),
        {"i": third},
    )
    await migrated_db.commit()


async def test_defaults_let_a_minimal_row_insert(migrated_db):
    """A client writing only the fields it knows about must not be rejected."""
    household_id, user_id, task_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await migrated_db.execute(
        text("INSERT INTO households (id, name, invite_code) VALUES (:i, 'Home', 'XYZ999')"),
        {"i": household_id},
    )
    await migrated_db.execute(
        text("INSERT INTO users (id, household_id, display_name) VALUES (:i, :h, 'Me')"),
        {"i": user_id, "h": household_id},
    )
    await migrated_db.execute(
        text("INSERT INTO tasks (id, household_id, title, created_by) VALUES (:i, :h, 'Milk', :u)"),
        {"i": task_id, "h": household_id, "u": user_id},
    )
    row = (
        await migrated_db.execute(
            text(
                "SELECT travel_mode, is_all_day, recurrence_exceptions, deleted_at "
                "FROM tasks WHERE id = :i"
            ),
            {"i": task_id},
        )
    ).one()
    assert row.travel_mode == "none"
    assert row.is_all_day is False
    assert row.recurrence_exceptions == []
    assert row.deleted_at is None
    await migrated_db.commit()
