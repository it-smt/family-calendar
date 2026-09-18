"""The two schemas have to stay identical.

Stage 1 says: the same model on both sides. Nothing enforces that by itself —
the server is Postgres and the device is SQLite, and they drift the moment
someone adds a column to one of them. These tests read the actual client DDL
and the actual migrated Postgres schema and compare them.

The Swift records are checked by text rather than by compiling them: there is no
Swift toolchain in CI here, and a mistyped `CodingKeys` string is exactly the
kind of error that would otherwise only show up at runtime on a device.
"""

from __future__ import annotations

import pathlib
import re
import sqlite3

import pytest
from sqlalchemy import inspect

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CLIENT_SOURCES = REPO_ROOT / "ios/FamilyCalendarKit/Sources/FamilyCalendarKit"
CLIENT_MIGRATIONS = [
    CLIENT_SOURCES / "Database/SQL/v1_initial.sql",
    CLIENT_SOURCES / "Database/SQL/v2_superseded_edits.sql",
    CLIENT_SOURCES / "Database/SQL/v3_route_cache.sql",
    CLIENT_SOURCES / "Database/SQL/v4_activity_notified.sql",
    CLIENT_SOURCES / "Database/SQL/v5_drop_apns_token.sql",
]
# Records live wherever they belong, not only in Models/, so the parser
# looks through the whole package rather than one folder.
CLIENT_MODELS = CLIENT_SOURCES

# The device carries an outbox flag; the server has no use for one.
CLIENT_ONLY_COLUMNS = {"dirty"}

#: Device-only columns on one table each, kept separate so a stray column
#: somewhere else is still caught.
EXTRA_CLIENT_COLUMNS = {
    # Which feed entries this person has already been told about. The other
    # phone keeps its own answer, because the two are told different things.
    "activity_entries": {"notified"},
}
# The cursor source lives only on the server, the cursor value only on the device.
# Neither credentials nor push tokens ever reach a device. An email and a
# password hash copied onto both phones would be a schema mistake; a push token
# is worse, because it belongs to one device and travelling through a shared row
# lets the other phone overwrite it.
SERVER_ONLY_TABLES = {"change_log", "alembic_version", "credentials", "devices"}
# Device bookkeeping: the cursor, and the edits an arriving row replaced.
CLIENT_ONLY_TABLES = {"sync_state", "superseded_edits", "route_cache", "sqlite_sequence"}

# How a Postgres type has to be spelled in SQLite for a value to survive the
# round trip without translation.
TYPE_EQUIVALENTS = {
    "UUID": "TEXT",
    "TEXT": "TEXT",
    "VARCHAR": "TEXT",
    "TIMESTAMP": "TEXT",
    "JSONB": "TEXT",
    "BOOLEAN": "INTEGER",
    "INTEGER": "INTEGER",
    "BIGINT": "INTEGER",
    "DOUBLE PRECISION": "REAL",
    "FLOAT": "REAL",
    # Enums are native types on the server and CHECK-constrained text here.
    "TRAVEL_MODE": "TEXT",
    "REMINDER_KIND": "TEXT",
}


@pytest.fixture(scope="module")
def client_schema() -> sqlite3.Connection:
    connection = sqlite3.connect(":memory:")
    connection.execute("PRAGMA foreign_keys = ON")
    for migration in CLIENT_MIGRATIONS:
        connection.executescript(migration.read_text())
    return connection


def client_tables(connection: sqlite3.Connection) -> set[str]:
    rows = connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    )
    return {name for (name,) in rows}


def client_columns(connection: sqlite3.Connection, table: str) -> dict[str, str]:
    return {
        row[1]: row[2].upper() for row in connection.execute(f"PRAGMA table_info({table})")
    }


async def test_the_same_tables_exist_on_both_sides(migrated_db, client_schema):
    def tables(connection):
        return set(inspect(connection).get_table_names())

    server = await migrated_db.run_sync(tables) - SERVER_ONLY_TABLES
    client = client_tables(client_schema) - CLIENT_ONLY_TABLES

    assert server == client


async def test_the_same_columns_exist_on_both_sides(migrated_db, client_schema):
    def columns(connection):
        inspector = inspect(connection)
        return {
            table: {column["name"] for column in inspector.get_columns(table)}
            for table in set(inspector.get_table_names()) - SERVER_ONLY_TABLES
        }

    server = await migrated_db.run_sync(columns)
    mismatches = {}
    for table, server_names in server.items():
        client_names = (
            set(client_columns(client_schema, table))
            - CLIENT_ONLY_COLUMNS
            - EXTRA_CLIENT_COLUMNS.get(table, set())
        )
        if client_names != server_names:
            mismatches[table] = {
                "only_on_server": sorted(server_names - client_names),
                "only_on_client": sorted(client_names - server_names),
            }

    assert mismatches == {}


async def test_column_types_round_trip(migrated_db, client_schema):
    """A UUID must be TEXT on the device, a bool INTEGER, a timestamp TEXT."""

    def columns(connection):
        inspector = inspect(connection)
        return {
            table: {
                column["name"]: str(column["type"]).split("(")[0].upper()
                for column in inspector.get_columns(table)
            }
            for table in set(inspector.get_table_names()) - SERVER_ONLY_TABLES
        }

    server = await migrated_db.run_sync(columns)
    mismatches = []
    for table, server_types in server.items():
        client_types = client_columns(client_schema, table)
        for name, server_type in server_types.items():
            expected = TYPE_EQUIVALENTS.get(server_type)
            assert expected is not None, f"no mapping for {server_type} ({table}.{name})"
            if client_types[name] != expected:
                mismatches.append(f"{table}.{name}: {server_type} -> {client_types[name]}, want {expected}")

    assert mismatches == []


async def test_every_synced_client_table_has_a_dirty_flag(client_schema):
    for table in client_tables(client_schema) - CLIENT_ONLY_TABLES:
        assert "dirty" in client_columns(client_schema, table), f"{table} has no outbox flag"


def swift_records() -> dict[str, set[str]]:
    """Map each Swift record's table name to the column names it encodes."""
    records: dict[str, set[str]] = {}
    for path in sorted(CLIENT_MODELS.rglob("*.swift")):
        source = path.read_text()

        # struct Name { ... enum CodingKeys ... }, and the table name declared
        # either in the struct or in its TableRecord extension.
        tables = dict(
            re.findall(r"(?:struct|extension)\s+(\w+)[^{]*\{(?:[^{}]|\{[^{}]*\})*?databaseTableName\s*=\s*\"(\w+)\"", source)
        )
        for match in re.finditer(
            r"public struct (\w+):.*?enum CodingKeys: String, CodingKey \{(.*?)\n    \}",
            source,
            re.DOTALL,
        ):
            type_name, body = match.group(1), match.group(2)
            table = tables.get(type_name)
            if table is None:
                continue
            columns = set()
            for case in re.finditer(r"case (\w+)(?:\s*=\s*\"(\w+)\")?", body):
                columns.add(case.group(2) or case.group(1))
            records[table] = columns
    return records


def test_swift_records_cover_every_client_column(client_schema):
    records = swift_records()
    assert records, "no Swift records were parsed — the parser or the models moved"

    for table, columns in records.items():
        expected = set(client_columns(client_schema, table))
        assert columns == expected, (
            f"{table}: Swift encodes {sorted(columns)}, the table has {sorted(expected)}"
        )


def test_every_synced_table_has_a_swift_record(client_schema):
    missing = client_tables(client_schema) - set(swift_records())
    assert missing == set()


async def test_a_pulled_change_inserts_into_the_device_database_unchanged(
    api, family, client_schema
):
    """The point of the whole wire format, checked end to end.

    A payload that came out of `/sync/pull` goes straight into the SQLite schema
    the device runs, with no translation beyond what GRDB does for a JSON column.
    If this test needs a conversion added to it, the device needs one too.
    """
    import json
    import uuid as uuid_module

    from tests.conftest import change, task_payload, wire_time

    task_id = uuid_module.uuid4()
    pushed = task_payload(
        family,
        task_id=task_id,
        title="Pool",
        notes="bring the certificate",
        starts_at=wire_time(60),
        duration_minutes=90,
        is_all_day=False,
        location_name="Sport complex",
        latitude=55.751244,
        longitude=37.618423,
        rrule="FREQ=WEEKLY;BYDAY=SA",
        recurrence_exceptions=[wire_time(10080)],
        travel_mode="driving",
        assignee_id=str(family.bob_id),
    )
    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", pushed)]},
        headers=family.headers(),
    )
    assert response.status_code == 200

    pulled = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()
    payload = next(c["payload"] for c in pulled["changes"] if c["entity_type"] == "task")

    # GRDB stores an array property as JSON text; everything else goes in as is.
    values = {
        key: json.dumps(value) if isinstance(value, (list, dict)) else value
        for key, value in payload.items()
    }
    columns = ", ".join(values)
    placeholders = ", ".join(f":{name}" for name in values)
    client_schema.execute(
        "INSERT INTO households (id, name, invite_code, created_at, updated_at) "
        "VALUES (:h, 'Home', 'PARITY', :t, :t)",
        {"h": payload["household_id"], "t": payload["updated_at"]},
    )
    for user_id in (payload["created_by"], payload["assignee_id"]):
        client_schema.execute(
            "INSERT INTO users (id, household_id, display_name, created_at, updated_at) "
            "VALUES (:u, :h, 'Someone', :t, :t)",
            {"u": user_id, "h": payload["household_id"], "t": payload["updated_at"]},
        )
    client_schema.execute(f"INSERT INTO tasks ({columns}) VALUES ({placeholders})", values)

    stored = client_schema.execute(
        "SELECT title, starts_at, duration_minutes, is_all_day, latitude, "
        "travel_mode, recurrence_exceptions, dirty FROM tasks WHERE id = :i",
        {"i": payload["id"]},
    ).fetchone()

    assert stored[0] == "Pool"
    assert stored[1] == wire_time(60)
    assert stored[2] == 90
    assert stored[3] == 0
    assert stored[4] == 55.751244
    assert stored[5] == "driving"
    assert json.loads(stored[6]) == [wire_time(10080)]
    # A row that arrived from the server is not waiting to be sent back.
    assert stored[7] == 0

    client_schema.rollback()


def swift_entity_tables() -> dict[str, str]:
    """The entity-to-table map the Swift sync layer uses, read out of the source."""
    source = (CLIENT_SOURCES / "Sync/SyncEntity.swift").read_text()
    body = re.search(r"public var tableName: String \{(.*?)\n    \}", source, re.DOTALL)
    assert body, "SyncEntity.tableName moved; the parser needs updating"

    cases = dict(re.findall(r'case \.(\w+): "(\w+)"', body.group(1)))
    # Map the Swift case names back to the wire names they carry.
    wire = dict(re.findall(r'case (\w+)(?: = "(\w+)")?\n', source))
    return {wire.get(name) or name: table for name, table in cases.items()}


def test_the_swift_sync_layer_names_the_right_tables(client_schema):
    """A typo here would compile and then quietly sync nothing."""
    mapped = swift_entity_tables()
    tables = client_tables(client_schema) - CLIENT_ONLY_TABLES

    assert set(mapped.values()) == tables


def test_the_swift_entity_types_match_the_servers():
    from app.sync.registry import ENTITY_TYPES

    assert set(swift_entity_tables()) == set(ENTITY_TYPES)


#: The layers the spec lays down: Store -> Repository -> ViewModel -> View, with
#: the network invisible above the repositories.
NETWORK_TYPES = ("SyncAPI", "SyncEngine", "URLSession", "NWPathMonitor", "CredentialStore")

UI_SOURCES = CLIENT_SOURCES.parent / "FamilyCalendarUI"


#: Where the layers are assembled: the environment that owns the engine, and the
#: launch path, which includes the one screen with nothing local to work from
#: yet. Everything else in the UI module reads the database and nothing else.
COMPOSITION_ROOT = {"AppEnvironment.swift"}


def test_the_network_layer_is_invisible_above_the_repositories():
    """A view model that can reach the network will eventually wait for it.

    The whole point of the architecture is that the UI reads the database and
    nothing else. AppEnvironment wires the engine up once and hands out
    repositories; no view or view model is allowed to name the network.
    """
    offenders = {}
    for path in sorted(UI_SOURCES.rglob("*.swift")):
        if path.name in COMPOSITION_ROOT or path.parent.name == "App":
            continue
        source = path.read_text()
        named = [name for name in NETWORK_TYPES if re.search(rf"\b{name}\b", source)]
        if named:
            offenders[path.name] = named

    assert offenders == {}


def test_every_write_from_the_ui_goes_through_a_repository():
    """No view or view model may write to the database directly."""
    offenders = {}
    for path in sorted(UI_SOURCES.rglob("*.swift")):
        source = path.read_text()
        named = [
            name
            for name in ("database.writer", "db.execute", "AppDatabase(")
            if name in source
        ]
        if named:
            offenders[path.name] = named

    assert offenders == {}
