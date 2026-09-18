"""The generated client SQL must match what the generator produces.

The device's conflict resolution lives in those files. They are committed so
Swift can ship them as resources and so a reader can see the rules without
running anything — which only works while the committed text and the generator
agree.
"""

from __future__ import annotations

import pathlib
import re
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from generate_client_sql import OUTPUT, generate  # noqa: E402

CLIENT_SCHEMA = (
    ROOT / "ios/FamilyCalendarKit/Sources/FamilyCalendarKit/Database/SQL/v1_initial.sql"
)


def test_the_committed_files_are_what_the_generator_produces():
    expected = generate()
    committed = {path.stem: path.read_text() for path in OUTPUT.glob("*.sql")}

    assert committed == expected, "run python tools/generate_client_sql.py"


def test_every_generated_statement_is_valid_sqlite():
    connection = sqlite3.connect(":memory:")
    connection.executescript(CLIENT_SCHEMA.read_text())

    for entity_type, sql in generate().items():
        statement = sql.rstrip().rstrip(";")
        # EXPLAIN compiles the statement against the real schema without running
        # it, which is the whole check: every column and every table has to
        # exist and the syntax has to be one this SQLite understands.
        parameters = {name: None for name in re.findall(r":(\w+)", statement)}
        connection.execute(f"EXPLAIN {statement}", parameters)


def test_the_rules_are_the_ones_the_protocol_asks_for():
    """A cheap guard on the shape, so a regenerated file cannot quietly drop one."""
    for entity_type, sql in generate().items():
        assert "COALESCE(excluded.updated_by, '')" in sql, entity_type
        assert "deleted_at = COALESCE(" in sql, entity_type
        assert "dirty = CASE WHEN" in sql, entity_type
        assert "excluded.deleted_at IS NOT NULL" in sql, entity_type
