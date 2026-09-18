"""Applying a push, and reading a pull.

Conflict resolution happens inside one SQL statement per row, not in Python.
Read-compare-write in the application would race two simultaneous pushes against
each other: both read the old row, both decide they are newer, and the second
one silently overwrites the first.

Two rules, from the protocol:

* last-write-wins on `updated_at`, with `updated_by` as a deterministic
  tie-break when two devices produce the same timestamp;
* deletion always wins — a tombstone applies even when it loses on time, and a
  deleted row is never resurrected.

Those two pull in different directions, so a losing-but-deleting row updates
`deleted_at` only and leaves the newer field values alone. The row is deleted
either way; what matters is that neither rule quietly cancels the other.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Table, and_, case, func, literal, or_, select
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import ActivityEntry, ChangeLog
from app.sync.registry import EntitySpec, spec_for
from app.sync.serialization import row_to_payload

#: Columns the upsert never copies from an incoming row.
IMMUTABLE_COLUMNS = frozenset({"id", "created_at", "household_id"})

_ZERO_UUID = literal(uuid.UUID(int=0), type_=PgUUID(as_uuid=True))


@dataclass
class AppliedChange:
    entity_type: str
    entity_id: uuid.UUID
    payload: dict[str, Any]
    seq: int | None = None


@dataclass
class PushResult:
    applied: list[AppliedChange] = field(default_factory=list)
    #: The highest `seq` this push wrote. Informational: a device must not move
    #: its pull cursor here, or it would skip changes its partner committed
    #: between its last pull and this push.
    server_cursor: int = 0


async def lock_household(session: AsyncSession, household_id: uuid.UUID) -> None:
    """Serialise pushes within one household for the duration of the transaction.

    `change_log.seq` comes from a sequence, and a sequence hands out numbers at
    insert time while a transaction becomes visible at commit time. Without this
    lock, a push that took number 5 could commit after one that took number 6,
    and a device that pulled in between would move its cursor past 6 and never
    see 5 again. Two people in one household never contend for this.
    """
    await session.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(str(household_id), 0)))
    )


def _lww_wins(table: Table, excluded) -> Any:
    return or_(
        excluded.updated_at > table.c.updated_at,
        and_(
            excluded.updated_at == table.c.updated_at,
            func.coalesce(excluded.updated_by, _ZERO_UUID)
            > func.coalesce(table.c.updated_by, _ZERO_UUID),
        ),
    )


def upsert_statement(table: Table, values: dict[str, Any]):
    """One statement that resolves the conflict in the database."""
    statement = pg_insert(table).values(**values)
    excluded = statement.excluded
    wins = _lww_wins(table, excluded)

    assignments: dict[str, Any] = {
        name: case((wins, excluded[name]), else_=table.c[name])
        for name in values
        if name not in IMMUTABLE_COLUMNS and name not in {"deleted_at", "updated_at"}
    }
    # A tombstone is permanent, and it applies whether or not it won on time.
    # When the payload carries no `deleted_at`, `excluded.deleted_at` is the
    # column default (NULL) and this leaves the current value untouched.
    assignments["deleted_at"] = func.coalesce(table.c.deleted_at, excluded.deleted_at)
    # Never move a row's clock backwards, even when an older tombstone lands.
    assignments["updated_at"] = func.greatest(table.c.updated_at, excluded.updated_at)

    return (
        statement.on_conflict_do_update(
            index_elements=[table.c.id],
            set_=assignments,
            where=or_(
                wins,
                and_(excluded.deleted_at.isnot(None), table.c.deleted_at.is_(None)),
            ),
        )
        .returning(table)
    )


async def _pre_images(
    session: AsyncSession, spec: EntitySpec, ids: list[uuid.UUID]
) -> dict[uuid.UUID, dict[str, Any]]:
    """The state of these rows before the push, for naming what happened."""
    table = spec.table
    columns = [table.c.id, table.c.deleted_at]
    if "completed_at" in table.c:
        columns.append(table.c.completed_at)
    result = await session.execute(select(*columns).where(table.c.id.in_(ids)))
    return {row.id: dict(row._mapping) for row in result}


def _action(pre: dict[str, Any] | None, row) -> str:
    mapping = row._mapping
    if pre is None:
        return "created"
    if mapping["deleted_at"] is not None and pre["deleted_at"] is None:
        return "deleted"
    if (
        "completed_at" in mapping
        and mapping["completed_at"] is not None
        and pre.get("completed_at") is None
    ):
        return "completed"
    return "updated"


async def _record_changes(
    session: AsyncSession,
    household_id: uuid.UUID,
    entries: list[tuple[str, uuid.UUID, dict[str, Any]]],
) -> list[int]:
    """Append to the change log and return the sequence numbers assigned."""
    if not entries:
        return []
    result = await session.execute(
        pg_insert(ChangeLog.__table__)
        .values(
            [
                {
                    "household_id": household_id,
                    "entity_type": entity_type,
                    "entity_id": entity_id,
                    "payload": payload,
                }
                for entity_type, entity_id, payload in entries
            ]
        )
        .returning(ChangeLog.__table__.c.seq)
    )
    return [seq for (seq,) in result]


async def _log_activity(
    session: AsyncSession,
    household_id: uuid.UUID,
    actor_id: uuid.UUID,
    events: list[tuple[EntitySpec, str, Any]],
) -> list[tuple[str, uuid.UUID, dict[str, Any]]]:
    """Write feed entries so no change lands silently on the other device.

    The entry stores the verb and the entity's label, not a sentence: the phrase
    ("she moved the doctor to 16:00") is built on the device, where the language
    and the reader's own name are known.
    """
    rows = []
    for spec, action, applied_row in events:
        label = ""
        if spec.label_column:
            label = applied_row._mapping.get(spec.label_column) or ""
        now = datetime.now(UTC)
        rows.append(
            {
                "id": uuid.uuid4(),
                "household_id": household_id,
                "actor_id": actor_id,
                "entity_type": spec.entity_type,
                "entity_id": applied_row._mapping["id"],
                "action": action,
                "summary": label,
                "created_at": now,
                "updated_at": now,
                "updated_by": actor_id,
            }
        )

    if not rows:
        return []

    result = await session.execute(
        pg_insert(ActivityEntry.__table__).values(rows).returning(ActivityEntry.__table__)
    )
    return [
        ("activity_entry", row._mapping["id"], row_to_payload(row)) for row in result
    ]


async def apply_push(
    session: AsyncSession,
    household_id: uuid.UUID,
    user_id: uuid.UUID,
    changes: list[tuple[str, dict[str, Any]]],
) -> PushResult:
    """Apply a whole batch, or none of it.

    The caller holds the transaction: everything here either commits together or
    rolls back together, which is what lets a device treat a push as a single
    step that either happened or did not.
    """
    await lock_household(session, household_id)

    by_type: dict[str, list[dict[str, Any]]] = {}
    for entity_type, values in changes:
        by_type.setdefault(entity_type, []).append(values)

    pre_images: dict[str, dict[uuid.UUID, dict[str, Any]]] = {}
    for entity_type, rows in by_type.items():
        spec = spec_for(entity_type)
        assert spec is not None  # the endpoint rejects unknown types
        pre_images[entity_type] = await _pre_images(
            session, spec, [row["id"] for row in rows]
        )

    result = PushResult()
    log_entries: list[tuple[str, uuid.UUID, dict[str, Any]]] = []
    activity_events: list[tuple[EntitySpec, str, Any]] = []

    for entity_type, values in changes:
        spec = spec_for(entity_type)
        assert spec is not None

        values = dict(values)
        if "household_id" in spec.table.c:
            # Never trust the payload for this: it decides who can read the row.
            values["household_id"] = household_id
        values.setdefault("updated_by", user_id)

        applied = (await session.execute(upsert_statement(spec.table, values))).first()
        if applied is None:
            # The stored row won. Nothing changed, so nothing is logged — an
            # idempotent re-push must not move the cursor, or two devices would
            # keep waking each other over changes neither of them made.
            continue

        payload = row_to_payload(applied)
        result.applied.append(
            AppliedChange(entity_type=entity_type, entity_id=applied._mapping["id"], payload=payload)
        )
        log_entries.append((entity_type, applied._mapping["id"], payload))

        if spec.logs_activity:
            pre = pre_images[entity_type].get(applied._mapping["id"])
            activity_events.append((spec, _action(pre, applied), applied))

    log_entries.extend(await _log_activity(session, household_id, user_id, activity_events))

    seqs = await _record_changes(session, household_id, log_entries)
    # `log_entries` holds the applied rows first, in order, then the feed
    # entries, so the leading sequence numbers are the ones the device asked for.
    for applied_change, seq in zip(result.applied, seqs, strict=False):
        applied_change.seq = seq
    result.server_cursor = max(seqs, default=0)
    return result


@dataclass
class PullPage:
    changes: list[AppliedChange]
    cursor: int
    has_more: bool


async def read_changes(
    session: AsyncSession, household_id: uuid.UUID, since: int, limit: int
) -> PullPage:
    """Everything that happened in this household after `since`.

    The cursor is `change_log.seq`. A device that has been offline for a month
    walks the pages until `has_more` is false.
    """
    table = ChangeLog.__table__
    result = await session.execute(
        select(table.c.seq, table.c.entity_type, table.c.entity_id, table.c.payload)
        .where(table.c.household_id == household_id, table.c.seq > since)
        .order_by(table.c.seq)
        .limit(limit + 1)
    )
    rows = result.all()

    has_more = len(rows) > limit
    rows = rows[:limit]

    return PullPage(
        changes=[
            AppliedChange(
                entity_type=row.entity_type,
                entity_id=row.entity_id,
                payload=row.payload,
                seq=row.seq,
            )
            for row in rows
        ],
        cursor=rows[-1].seq if rows else since,
        has_more=has_more,
    )
