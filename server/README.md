# family-calendar server

Transport for changes between two devices. The device database is the source of
truth; nothing here is authoritative except the `change_log` sequence.

## Push notifications

Optional. With none of it set the server does not wake the other phone, and
everything still synchronises on launch, on foreground, and when the network
comes back — later, but never wrong.

```sh
export FC_APNS_KEY_ID=ABC123DEFG
export FC_APNS_TEAM_ID=TEAM123456
export FC_APNS_TOPIC=com.example.familycalendar   # the app's bundle id
export FC_APNS_KEY_PATH=/run/secrets/AuthKey_ABC123DEFG.p8
export FC_APNS_USE_SANDBOX=true                    # false for TestFlight and the App Store
```

The push carries `content-available: 1` and nothing else. It says "something
changed"; the device wakes, pulls, and reads the change from the database as
always. Putting the data in the notification would make delivery part of the
protocol, and APNs promises no delivery — a dropped push would become a lost
change.

Tokens live in `devices`, not on `users`. A token belongs to a device rather
than to a person, and `users` is a synchronised row: whole-row last-write-wins
would let the partner's phone push back a stale copy and silently unregister a
device it knows nothing about.

## Local run

```sh
docker compose up -d db
export FC_DATABASE_URL=postgresql+asyncpg://fc:fc@localhost:5432/family_calendar
alembic upgrade head
```

## Tests

Tests need a real Postgres. Point them at a throwaway database:

```sh
createdb family_calendar_test
export FC_TEST_DATABASE_URL=postgresql+asyncpg://fc:fc@localhost:5432/family_calendar_test
pytest
```

Each test migrates to head and back down to base, so the database is left empty.

## Stage 1 status

Schema only — no endpoints yet. `app/main.py` arrives with the sync core.
