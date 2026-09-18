"""Per-entity validation, derived from the tables themselves.

The schema already exists in two places (Postgres and SQLite) and is mirrored by
the Swift records. Hand-writing a third copy as Pydantic models would be a
fourth place to forget a column, so these are generated from the SQLAlchemy
columns instead.

Validation is strict about two things and lenient about everything else: an
unknown column is rejected, because it means the device and the server disagree
about the schema; and a column the device did not send is simply not written,
so a partial payload updates only what it carries.
"""

from __future__ import annotations

from functools import cache
from typing import Any

from pydantic import BaseModel, ConfigDict, create_model
from sqlalchemy import Column, Table
from sqlalchemy.dialects.postgresql import JSONB

from app.sync.registry import SPECS_BY_TYPE

#: Columns the server owns. A device may send them; they are ignored.
SERVER_OWNED = frozenset({"created_at"})

#: The server fills these in from the caller's identity, so a payload need not
#: carry them — and if it does, the value is replaced.
SERVER_SUPPLIED = frozenset({"household_id"})

#: Required whatever the column defaults say. `updated_at` decides every
#: conflict, so a payload without one is a broken client, not a new row with a
#: server timestamp.
ALWAYS_REQUIRED = frozenset({"id", "updated_at"})


def _python_type(column: Column) -> Any:
    if isinstance(column.type, JSONB):
        return list | dict
    try:
        return column.type.python_type
    except NotImplementedError:  # pragma: no cover - no such column today
        return Any


def _field(column: Column) -> tuple[Any, Any]:
    annotation = _python_type(column)
    if column.nullable:
        annotation = annotation | None
    if column.name in ALWAYS_REQUIRED:
        return (annotation, ...)
    optional = (
        column.nullable
        or column.name in SERVER_SUPPLIED
        or column.default is not None
        or column.server_default is not None
    )
    return (annotation, None if optional else ...)


def _model_for_table(table: Table, name: str) -> type[BaseModel]:
    fields = {
        column.name: _field(column)
        for column in table.columns
        if column.name not in SERVER_OWNED
    }
    return create_model(
        name,
        __config__=ConfigDict(extra="forbid", str_strip_whitespace=False),
        **fields,
    )


@cache
def payload_model(entity_type: str) -> type[BaseModel]:
    """The validator for one entity's payload."""
    spec = SPECS_BY_TYPE[entity_type]
    return _model_for_table(spec.table, f"{entity_type.title().replace('_', '')}Payload")


def validate_payload(entity_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Validated column values, holding only the columns the device actually sent."""
    model = payload_model(entity_type)
    validated = model.model_validate(payload)
    return validated.model_dump(exclude_unset=True, exclude=set(SERVER_OWNED))
