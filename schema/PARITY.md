# Schema parity: Postgres ↔ SQLite

Stage 1 says the model is identical on both sides. It is not identical by
accident — `server/tests/test_client_schema_parity.py` reads both schemas and
fails if they drift. Run it before touching either one:

```sh
cd server && pytest tests/test_client_schema_parity.py
```

The two sources of truth for the schema itself:

| Side | File |
|---|---|
| Server | `server/alembic/versions/0001_initial_schema.py` (generated from `server/app/db/models/`) |
| Device | `ios/FamilyCalendarKit/Sources/FamilyCalendarKit/Database/SQL/v1_initial.sql` |

## Deliberate differences

| Difference | Why |
|---|---|
| `dirty` exists only on the device | It is the outbox flag: the row has not reached the server yet. The server has nothing to do with it. |
| `change_log` exists only on the server | It is where the pull cursor comes from. |
| `sync_state` exists only on the device | One row, holding the cursor the device has reached. Never pushed. |
| Enums are native types on the server, `TEXT` + `CHECK` on the device | Same string values on both sides. |
| The server has no CHECK constraints | A constraint the client can violate would reject a push the device has already committed locally, and the device would retry it forever. Cross-field rules belong on the device, before the row is written. |
| The device has CHECK constraints | It may constrain its own writes freely — a rejection there is a bug caught at the source. |

## Type mapping

A value has to survive the trip through a JSON change payload unchanged, so the
device stores it in the shape the server serialises it to.

| Postgres | SQLite | Swift | On the wire |
|---|---|---|---|
| `uuid` | `TEXT` | `UUID` | uppercase string, e.g. `9F2A...` |
| `timestamptz` | `TEXT` | `Date` | RFC 3339, UTC, milliseconds |
| `text` / `varchar` | `TEXT` | `String` | string |
| `boolean` | `INTEGER` | `Bool` | `0` / `1` → `true` / `false` |
| `integer` / `bigint` | `INTEGER` | `Int` / `Int64` | number |
| `double precision` | `REAL` | `Double` | number |
| `jsonb` | `TEXT` | `[String]` | JSON array |
| `travel_mode` | `TEXT CHECK` | `TravelMode` | `none` \| `walking` \| `driving` \| `transit` |
| `reminder_kind` | `TEXT CHECK` | `ReminderKind` | `fixed` \| `leave_time` \| `geo` |

The strategies that produce those shapes live in
`Sources/FamilyCalendarKit/Models/SyncRecord.swift` (`.uppercaseString` for
UUIDs, a custom RFC 3339 strategy for dates) and in
`Database/Timestamp.swift`.

## Columns every synchronised entity carries

`id`, `household_id`, `created_at`, `updated_at`, `updated_by`, `deleted_at`
(+ `dirty` on the device). `households` has all of them except `household_id` —
it is the scope, so it does not point at one.

`id` is generated on the device. Nothing in either schema autoincrements except
`change_log.seq`, which is the one value only the server may assign.

## Naming

Columns are `snake_case` on both sides; the Swift records map them through
explicit `CodingKeys`, which the parity test checks string by string.

The Swift type for a task is `CalendarTask`, not `Task`: a type called `Task`
inside the module shadows Swift concurrency's `Task`. The table is still `tasks`.
