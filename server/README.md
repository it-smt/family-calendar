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

## Running it where both phones can reach it

`docker compose up` is for your own machine. Both phones talking to one
deployment is `docker-compose.prod.yml`, which differs in four ways that
matter: Postgres is not published on the host, the application is not mounted
from the working copy, Caddy holds a real certificate in front, and nothing has
a default — a secret with a fallback is a secret that ships.

You need a machine that stays on and a name pointing at it. A two-euro VPS is
plenty: this is a calendar for two people, and the database will not reach a
gigabyte in a decade.

One trap worth naming: `POSTGRES_PASSWORD` is put into a connection URL, so
generate it with `openssl rand -hex 32` rather than base64. A `/` or a `+` in
there cuts the URL in half, and the error you get talks about a host name and
never mentions the password.

```sh
# On the server, with an A record for FC_DOMAIN already pointing here.
git clone <this repository> && cd family-calendar/server
cp .env.example .env
$EDITOR .env                      # every blank needs filling
docker compose -f docker-compose.prod.yml up -d --build
curl https://your.domain/health   # {"status":"ok"}
```

Caddy takes the certificate from Let's Encrypt on first start and renews it by
itself. That is the whole reason it is there rather than nginx and a certbot
cron job that fails quietly in March.

HTTPS is not decoration here. Both phones keep an access token in the Keychain
and send it on every request; over plain HTTP it is readable by every network
between the phone and the server, and it is valid for a year.

### Telling the phones where to look

The address is no longer compiled in. On first launch the sign-in screen has a
**Другой сервер** line: type `calendar.example.com` — the scheme is added if
you leave it off — and it is kept on that device and shown afterwards in
**Настройки → Этот телефон**. A build that already knows where it is going can
put `FCServerURL` in the app's Info.plist instead.

### Backups

The `backup` service dumps the database once a day into `./backups` and keeps a
month. Restoring:

```sh
docker compose -f docker-compose.prod.yml stop api
docker compose -f docker-compose.prod.yml exec -T db \
    pg_restore --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    < backups/family-calendar-<stamp>.dump
docker compose -f docker-compose.prod.yml start api
```

Worth doing once, on purpose, while nothing is wrong. A backup nobody has ever
restored is a file, not a backup.

### Signing a phone out from here

`FC_JWT_SECRET` signs every token. Changing it and restarting invalidates all
of them, which is how you deal with a phone you no longer have. Both people
then sign in again; nothing local is lost, because nothing local depends on the
token.
