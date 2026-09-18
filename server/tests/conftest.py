"""Test fixtures.

Every test runs against a real Postgres: a migration that only passes against
SQLAlchemy's idea of the schema is not a migration that has been tested.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from alembic import command
from alembic.config import Config
from sqlalchemy.ext.asyncio import AsyncConnection, create_async_engine

TEST_DATABASE_URL = os.environ.get(
    "FC_TEST_DATABASE_URL",
    "postgresql+asyncpg://fc:fc@127.0.0.1:5432/family_calendar_test",
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def alembic_config() -> Config:
    config = Config(os.path.join(ROOT, "alembic.ini"))
    config.set_main_option("script_location", os.path.join(ROOT, "alembic"))
    config.set_main_option("sqlalchemy.url", TEST_DATABASE_URL)
    return config


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    return "asyncio"


@pytest_asyncio.fixture
async def migrated_db() -> AsyncIterator[AsyncConnection]:
    """A database at head, torn all the way back down afterwards."""
    os.environ["FC_DATABASE_URL"] = TEST_DATABASE_URL
    config = alembic_config()

    # env.py drives its own event loop, so the migration runs off this one.
    await asyncio.to_thread(command.downgrade, config, "base")
    await asyncio.to_thread(command.upgrade, config, "head")

    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        yield connection
    await engine.dispose()

    await asyncio.to_thread(command.downgrade, config, "base")
