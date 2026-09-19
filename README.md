# family-calendar

A calendar for two people, on two phones.

The device's own database is the source of truth. The screen, the widget and
the alerts read it and never wait for a network: a change is safe the moment it
is written, and the server hears about it whenever there is a server to hear.
Two people editing the same thing from two aeroplanes converge afterwards, and
the one whose edit lost is told so rather than left to notice.

```
ios/
  FamilyCalendarKit/     the whole application, as a Swift package
    Sources/
      FamilyCalendarKit/ database, sync, recurrence, alerts, travel, widget data
      FamilyCalendarUI/  every screen and view model
    Tests/               what only a Swift compiler can check
  FamilyCalendar/        the app target: one file, holding @main
  FamilyCalendarWidget/  the widget's three files
  SETUP.md               Xcode, step by step
  CHECK-TOGETHER.md      the half hour with two phones that tests cannot do
server/
  app/                   FastAPI: auth, push, pull, APNs
  alembic/               the Postgres schema, one migration at a time
  tests/                 735 of them, including a reference device in Python
  README.md              running it, deploying it, backing it up
schema/PARITY.md         how the two schemas are kept honest
tools/                   generators: the device's SQL, the app icon
```

## How it is put together

**The device decides.** Every write goes to SQLite and returns. A `dirty` flag
is the outbox; the sync engine drains it when it can.

**The server is a postbox with a sequence.** It keeps a `change_log`, and a
device asks for everything after the number it last saw. Cursors are sequence
numbers, never timestamps: clocks disagree, `BIGSERIAL` does not.

**Conflicts resolve the same way on both sides.** Last-write-wins on
`updated_at`, `updated_by` as the tie-break, deletion wins unconditionally. The
SQL that does it on the device is generated from the server's own schema by
`tools/generate_client_sql.py`, so there is one description of the rule and two
copies of it that cannot drift.

**What the tests can reach, they reach.** The Python suite runs a reference
device against the real server, and the client algorithms that matter —
recurrence, the notification plan, the widget timeline, travel, geofences — have
transcriptions checked against it. Recurrence is validated against
`python-dateutil` on four hundred random rules.

**What they cannot reach is written down.** No Swift toolchain runs in CI here,
so `ios/FamilyCalendarKit/Tests` is run from Xcode, and `ios/CHECK-TOGETHER.md`
is the part that needs two phones and a person.

## Before two people use it

In the order that matters:

1. **Put the server somewhere both phones can reach** — `server/README.md`.
   Until then the second phone has nowhere to point.
2. **Run `ios/CHECK-TOGETHER.md`.** Half an hour, two simulators. It is the only
   thing that has ever tested the app rather than the protocol.
3. **Run the Swift tests once** (⌘U). They have never been executed here.
4. **Push notifications**, if you want the other phone to find out at once
   rather than on its next launch. Needs a paid developer account.
5. **The widget**, if you want one — `ios/SETUP.md`.
6. **Geofences and leave-time, outdoors.** A simulator cannot tell you whether
   these work; only walking out of the house can.
