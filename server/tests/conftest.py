"""Test fixtures.

Every test runs against a real Postgres: a migration that only passes against
SQLAlchemy's idea of the schema is not a migration that has been tested, and
conflict resolution that only works in SQLite proves nothing about the server.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
import pytest_asyncio
from alembic import command
from alembic.config import Config
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncConnection,
    AsyncEngine,
    async_sessionmaker,
    create_async_engine,
)

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
async def migrated() -> AsyncIterator[None]:
    """A database at head, torn all the way back down afterwards."""
    os.environ["FC_DATABASE_URL"] = TEST_DATABASE_URL
    config = alembic_config()

    # env.py drives its own event loop, so the migration runs off this one.
    await asyncio.to_thread(command.downgrade, config, "base")
    await asyncio.to_thread(command.upgrade, config, "head")

    yield

    await asyncio.to_thread(command.downgrade, config, "base")


@pytest_asyncio.fixture
async def db_engine(migrated: None) -> AsyncIterator[AsyncEngine]:
    engine = create_async_engine(TEST_DATABASE_URL)
    yield engine
    await engine.dispose()


@pytest_asyncio.fixture
async def migrated_db(db_engine: AsyncEngine) -> AsyncIterator[AsyncConnection]:
    async with db_engine.connect() as connection:
        yield connection


@dataclass(frozen=True)
class Family:
    """A household with its two people, which is the whole user base."""

    household_id: uuid.UUID
    alice_id: uuid.UUID
    bob_id: uuid.UUID

    def headers(self, user_id: uuid.UUID | None = None) -> dict[str, str]:
        return {
            "X-Household-Id": str(self.household_id),
            "X-User-Id": str(user_id or self.alice_id),
        }


async def _seed_family(engine: AsyncEngine) -> Family:
    family = Family(uuid.uuid4(), uuid.uuid4(), uuid.uuid4())
    async with engine.begin() as connection:
        await connection.execute(
            text("INSERT INTO households (id, name, invite_code) VALUES (:i, 'Home', :c)"),
            {"i": family.household_id, "c": str(family.household_id)[:8]},
        )
        for user_id, name in ((family.alice_id, "Alice"), (family.bob_id, "Bob")):
            await connection.execute(
                text(
                    "INSERT INTO users (id, household_id, display_name) "
                    "VALUES (:i, :h, :n)"
                ),
                {"i": user_id, "h": family.household_id, "n": name},
            )
    return family


@pytest_asyncio.fixture
async def family(db_engine: AsyncEngine) -> Family:
    return await _seed_family(db_engine)


@pytest_asyncio.fixture
async def other_family(db_engine: AsyncEngine) -> Family:
    """A second household, to prove one never sees the other's changes."""
    return await _seed_family(db_engine)


@pytest_asyncio.fixture
async def api(db_engine: AsyncEngine) -> AsyncIterator[AsyncClient]:
    from app.db.session import get_session
    from app.main import app

    factory = async_sessionmaker(db_engine, expire_on_commit=False, autoflush=False)

    async def session_override() -> AsyncIterator[Any]:
        async with factory() as session:
            yield session

    app.dependency_overrides[get_session] = session_override
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://sync.test") as client:
        yield client
    app.dependency_overrides.clear()


# --- payload helpers -------------------------------------------------------

BASE_TIME = datetime(2026, 9, 18, 9, 0, tzinfo=UTC)


def wire_time(offset_minutes: int = 0) -> str:
    """A timestamp in the format both sides speak."""
    moment = BASE_TIME + timedelta(minutes=offset_minutes)
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def task_payload(
    family: Family,
    *,
    task_id: uuid.UUID | None = None,
    title: str = "Doctor",
    updated_at: str | None = None,
    updated_by: uuid.UUID | None = None,
    **extra: Any,
) -> dict[str, Any]:
    payload = {
        "id": str(task_id or uuid.uuid4()),
        "household_id": str(family.household_id),
        "title": title,
        "created_by": str(family.alice_id),
        "updated_at": updated_at or wire_time(),
        "updated_by": str(updated_by or family.alice_id),
    }
    payload.update({key: value for key, value in extra.items()})
    return payload


def change(entity_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {"entity_type": entity_type, "payload": payload}
