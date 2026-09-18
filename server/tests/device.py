"""A reference device.

Not a mock: it runs the real client-side protocol against the real server. It
opens the same SQLite schema the app ships, applies pulled changes with the same
generated SQL the Swift code executes, and keeps its own outbox and cursor.

It exists because there is no Swift toolchain in CI here. The Swift client is a
thin layer over exactly these steps — URLSession instead of httpx, GRDB instead
of sqlite3 — so what this proves about the protocol holds for the app, while
what it cannot prove (that the Swift compiles) is left to Xcode.
"""

from __future__ import annotations

import json
import pathlib
import sqlite3
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any

CLIENT_ROOT = (
    pathlib.Path(__file__).resolve().parents[2]
    / "ios/FamilyCalendarKit/Sources/FamilyCalendarKit/Database"
)
SCHEMA_SQL = [CLIENT_ROOT / "SQL/v1_initial.sql", CLIENT_ROOT / "SQL/v2_superseded_edits.sql"]
APPLY_SQL = CLIENT_ROOT / "SQL/apply"
SUPERSEDE_SQL = CLIENT_ROOT / "SQL/supersede"

#: Tables the device may push, in the order dependencies want.
OUTBOX_ORDER = [
    ("household", "households"),
    ("user", "users"),
    ("category", "categories"),
    ("packing_template", "packing_templates"),
    ("task", "tasks"),
    ("reminder", "reminders"),
    ("subtask", "subtasks"),
    ("shopping_item", "shopping_items"),
]

#: Columns holding JSON. GRDB serialises these for a Swift array property; here
#: it is json.dumps. Everything else crosses unchanged.
JSON_COLUMNS = {"recurrence_exceptions", "items"}


def wire_time(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def next_updated_at(previous: str | None, now: datetime) -> str:
    """The next version stamp for a row, strictly after the one it replaces.

    Timestamps on the wire have millisecond resolution, so two edits a moment
    apart can land on the same value. Two versions of a row that compare equal
    are indistinguishable to last-write-wins: the second edit would lose to the
    first and be dropped by the server for good. A device must never produce
    two different versions of a row with the same stamp.
    """
    stamp = wire_time(now)
    if previous is not None and stamp <= previous:
        moment = datetime.fromisoformat(previous.replace("Z", "+00:00"))
        stamp = wire_time(moment + timedelta(milliseconds=1))
    return stamp


class Device:
    """One phone."""

    def __init__(
        self,
        api,
        *,
        token: str,
        household_id: str,
        user_id: str,
        name: str = "device",
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.api = api
        self.name = name
        self.token = token
        self.household_id = household_id
        self.user_id = user_id
        self.clock = clock or (lambda: datetime.now(UTC))

        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        for migration in SCHEMA_SQL:
            self.db.executescript(migration.read_text())
        self._apply_statements = {
            path.stem: path.read_text() for path in APPLY_SQL.glob("*.sql")
        }
        self._supersede_statements = {
            path.stem: path.read_text() for path in SUPERSEDE_SQL.glob("*.sql")
        }

    def close(self) -> None:
        self.db.close()

    # --- what the UI does ---------------------------------------------------

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def now(self) -> str:
        return wire_time(self.clock())

    def create_task(self, title: str, **fields: Any) -> str:
        """A local write. It lands in the database and is queued, never sent here."""
        task_id = str(uuid.uuid4()).upper()
        moment = self.now()
        values = {
            "id": task_id,
            "household_id": self.household_id,
            "title": title,
            "created_by": self.user_id,
            "created_at": moment,
            "updated_at": moment,
            "updated_by": self.user_id,
            "dirty": 1,
            **fields,
        }
        columns = ", ".join(values)
        placeholders = ", ".join(f":{name}" for name in values)
        self.db.execute(f"INSERT INTO tasks ({columns}) VALUES ({placeholders})", values)
        self.db.commit()
        return task_id

    def update_task(self, task_id: str, **fields: Any) -> None:
        current = self.db.execute(
            "SELECT updated_at FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        fields["updated_at"] = next_updated_at(
            current["updated_at"] if current else None, self.clock()
        )
        fields["updated_by"] = self.user_id
        fields["dirty"] = 1
        assignments = ", ".join(f"{name} = :{name}" for name in fields)
        self.db.execute(
            f"UPDATE tasks SET {assignments} WHERE id = :id", {**fields, "id": task_id}
        )
        self.db.commit()

    def delete_task(self, task_id: str) -> None:
        """A tombstone. The row itself is never removed."""
        self.update_task(task_id, deleted_at=self.now())

    def task(self, task_id: str) -> dict[str, Any] | None:
        row = self.db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
        return dict(row) if row else None

    def live_tasks(self) -> list[dict[str, Any]]:
        rows = self.db.execute(
            "SELECT * FROM tasks WHERE deleted_at IS NULL ORDER BY created_at, id"
        )
        return [dict(row) for row in rows]

    def dirty_count(self) -> int:
        return sum(
            self.db.execute(f"SELECT count(*) FROM {table} WHERE dirty = 1").fetchone()[0]
            for _, table in OUTBOX_ORDER
        )

    @property
    def cursor(self) -> int:
        return self.db.execute("SELECT pull_cursor FROM sync_state WHERE id = 1").fetchone()[0]

    # --- the protocol -------------------------------------------------------

    def collect_outbox(self) -> list[dict[str, Any]]:
        """Everything still marked dirty, oldest edit first."""
        outbox = []
        for entity_type, table in OUTBOX_ORDER:
            rows = self.db.execute(
                f"SELECT * FROM {table} WHERE dirty = 1 ORDER BY updated_at, id"
            )
            for row in rows:
                payload = {
                    key: (json.loads(value) if key in JSON_COLUMNS else value)
                    for key, value in dict(row).items()
                    if key != "dirty"
                }
                payload = {
                    key: (bool(value) if isinstance(value, int) and key.startswith(("is_", "on_")) else value)
                    for key, value in payload.items()
                }
                outbox.append(
                    {
                        "entity_type": entity_type,
                        "table": table,
                        "payload": payload,
                        "sent_updated_at": row["updated_at"],
                    }
                )
        return outbox

    async def send(self, outbox: list[dict[str, Any]]) -> dict[str, Any]:
        response = await self.api.post(
            "/sync/push",
            json={
                "changes": [
                    {"entity_type": item["entity_type"], "payload": item["payload"]}
                    for item in outbox
                ]
            },
            headers=self.headers,
        )
        response.raise_for_status()

        for item in outbox:
            # Only if the row has not been edited again while the request was in
            # flight. Clearing it blindly would drop an edit the user made a
            # second ago and the server has never seen.
            self.db.execute(
                f"UPDATE {item['table']} SET dirty = 0 "
                "WHERE id = :id AND updated_at = :sent",
                {"id": item["payload"]["id"], "sent": item["sent_updated_at"]},
            )
        self.db.commit()
        return response.json()

    async def push(self) -> dict[str, Any] | None:
        outbox = self.collect_outbox()
        if not outbox:
            return None
        return await self.send(outbox)

    def apply(self, entity_type: str, payload: dict[str, Any]) -> None:
        values = {
            key: (json.dumps(value) if key in JSON_COLUMNS else value)
            for key, value in payload.items()
        }
        # Before the row is replaced, keep whatever this person wrote into it.
        # Nothing is lost silently; the app offers to put it back.
        self.db.execute(
            self._supersede_statements[entity_type],
            {**values, "current_user_id": self.user_id},
        )
        self.db.execute(self._apply_statements[entity_type], values)

    def superseded_edits(self) -> list[dict[str, Any]]:
        rows = self.db.execute(
            "SELECT * FROM superseded_edits WHERE dismissed = 0 ORDER BY id"
        )
        return [
            {**dict(row), "mine": json.loads(row["mine"]), "theirs": json.loads(row["theirs"])}
            for row in rows
        ]

    async def pull(self, limit: int = 500) -> int:
        """Walk the pages until there are none left. Returns how many arrived."""
        applied = 0
        while True:
            response = await self.api.get(
                "/sync/pull",
                params={"since": self.cursor, "limit": limit},
                headers=self.headers,
            )
            response.raise_for_status()
            body = response.json()

            for change in body["changes"]:
                self.apply(change["entity_type"], change["payload"])
                applied += 1

            self.db.execute(
                "UPDATE sync_state SET pull_cursor = ?, last_synced_at = ? WHERE id = 1",
                (body["cursor"], self.now()),
            )
            self.db.commit()

            if not body["has_more"]:
                return applied

    async def sync(self, limit: int = 500) -> None:
        """Push first, then pull: send what is ours before taking what is theirs."""
        await self.push()
        await self.pull(limit=limit)


def skewed_clock(offset: timedelta) -> Callable[[], datetime]:
    """A device whose clock disagrees with the other one."""
    return lambda: datetime.now(UTC) + offset
