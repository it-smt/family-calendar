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
| `credentials` exists only on the server | The `users` table is copied to every device; an email and a password hash must not ride along with it. |
| `devices` exists only on the server | A push token belongs to one device. Travelling through a shared row would let the other phone overwrite it. |
| `sync_state` exists only on the device | One row, holding the cursor the device has reached. Never pushed. |
| `superseded_edits` exists only on the device | An edit of this person's that an arriving row replaced, kept so the loss is not silent. |
| `route_cache` exists only on the device | A route is measured from where *this* phone is; the other phone is somewhere else. |
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

## Conflict resolution runs on both sides

The device resolves conflicts too. A row arriving from a pull can be older than
an edit made offline and not yet pushed, and applying it blindly would lose that
edit. The rules are the same as the server's, and the SQL that implements them
is generated rather than written twice:

```sh
python tools/generate_client_sql.py   # -> Database/SQL/apply/*.sql
```

The Swift client ships those files as resources and executes them verbatim; the
protocol tests execute the same files against a real SQLite. `server/tests/
test_generated_sql.py` fails if the committed text stops matching the generator.

Two consequences worth knowing:

* **Timestamps compare as text.** That is only correct while every timestamp has
  the one fixed shape — RFC 3339, UTC, milliseconds. A value written without
  milliseconds would sort after one with them and invert last-write-wins, which
  is why `Timestamp.swift` has a single writer.
* **A replaced edit is kept, not dropped.** Last-write-wins compares whole rows,
  so when two people edit one task offline the later stamp takes the other's
  field with it — a field the winner never touched. Changing that means
  per-column versions or a CRDT, which is a different application. Instead
  `supersede/*.sql` runs just before `apply/*.sql` and keeps the version it is
  about to lose, so the app can show what was replaced and offer to put it back.
  Restoring is an ordinary local edit and wins the same way anything else does.
* **A version stamp must be strictly greater than the one it replaces.** Two
  edits in the same millisecond produce the same stamp, and two versions that
  compare equal are one version as far as last-write-wins is concerned: once the
  first is pushed, the second is dropped by the server and marked clean locally.
  `Timestamp.strictlyAfter` is what prevents that.

## Naming

Columns are `snake_case` on both sides; the Swift records map them through
explicit `CodingKeys`, which the parity test checks string by string.

The Swift type for a task is `CalendarTask`, not `Task`: a type called `Task`
inside the module shadows Swift concurrency's `Task`. The table is still `tasks`.
