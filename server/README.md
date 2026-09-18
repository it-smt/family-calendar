# family-calendar server

Transport for changes between two devices. The device database is the source of
truth; nothing here is authoritative except the `change_log` sequence.

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
