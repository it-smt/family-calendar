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
CLIENT_SCHEMA = CLIENT_SOURCES / "Database/SQL/v1_initial.sql"
CLIENT_MODELS = CLIENT_SOURCES / "Models"

# The device carries an outbox flag; the server has no use for one.
CLIENT_ONLY_COLUMNS = {"dirty"}
# The cursor source lives only on the server, the cursor value only on the device.
SERVER_ONLY_TABLES = {"change_log", "alembic_version"}
CLIENT_ONLY_TABLES = {"sync_state"}

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
    connection.executescript(CLIENT_SCHEMA.read_text())
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
        client_names = set(client_columns(client_schema, table)) - CLIENT_ONLY_COLUMNS
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
    for path in sorted(CLIENT_MODELS.glob("*.swift")):
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
