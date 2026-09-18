"""The migration has to be reversible, including the enum types it creates."""

from __future__ import annotations

import os

from alembic import command
from sqlalchemy import create_engine, inspect, text

from tests.conftest import TEST_DATABASE_URL, alembic_config

SYNC_URL = TEST_DATABASE_URL.replace("+asyncpg", "")


def test_down_up_down_up_cycle():
    os.environ["FC_DATABASE_URL"] = TEST_DATABASE_URL
    config = alembic_config()

    command.downgrade(config, "base")
    for _ in range(2):
        command.upgrade(config, "head")
        command.downgrade(config, "base")

    engine = create_engine(SYNC_URL)
    with engine.connect() as connection:
        tables = set(inspect(connection).get_table_names())
        assert "tasks" not in tables
        # A leftover enum type would break the next upgrade.
        leftover = connection.execute(
            text("SELECT typname FROM pg_type WHERE typname IN ('travel_mode', 'reminder_kind')")
        ).all()
        assert leftover == []
    engine.dispose()

    command.upgrade(config, "head")
    command.downgrade(config, "base")
