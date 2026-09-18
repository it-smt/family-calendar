"""Registration, joining, login.

Simple by design, but simple is not the same as careless: these pin down that
the household boundary follows the token and nothing else, and that a failed
login says the same thing whoever asks.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from sqlalchemy import text

from app.config import settings

ALICE = {
    "email": "alice@example.com",
    "password": "correct horse battery",
    "display_name": "Alice",
    "household_name": "Our place",
}
BOB = {"email": "bob@example.com", "password": "another good one", "display_name": "Bob"}


async def register(api, **overrides) -> dict:
    response = await api.post("/auth/register", json={**ALICE, **overrides})
    assert response.status_code == 201, response.text
    return response.json()


def bearer(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['access_token']}"}


async def test_registering_starts_a_household(api, db_engine):
    body = await register(api)

    assert body["token_type"] == "bearer"
    assert len(body["invite_code"]) == 8
    async with db_engine.connect() as connection:
        household = (
            await connection.execute(
                text("SELECT name, invite_code FROM households WHERE id = :i"),
                {"i": uuid.UUID(body["household_id"])},
            )
        ).one()
        user_count = await connection.scalar(text("SELECT count(*) FROM users"))
    assert household.name == "Our place"
    assert household.invite_code == body["invite_code"]
    assert user_count == 1


async def test_the_token_from_registration_works_on_sync(api):
    from tests.conftest import change, task_payload

    body = await register(api)

    class Fake:
        household_id = uuid.UUID(body["household_id"])
        alice_id = uuid.UUID(body["user_id"])

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(Fake, title="First task"))]},
        headers=bearer(body),
    )

    assert response.status_code == 200
    assert response.json()["applied"][0]["payload"]["title"] == "First task"


async def test_registration_is_recorded_in_the_change_log(api):
    """Otherwise the partner joins and never learns who is already there."""
    body = await register(api)

    pulled = (await api.get("/sync/pull", params={"since": 0}, headers=bearer(body))).json()
    kinds = [change["entity_type"] for change in pulled["changes"]]

    assert kinds == ["household", "user"]
    user_payload = pulled["changes"][1]["payload"]
    assert user_payload["display_name"] == "Alice"
    # The device gets the row, not the secrets that hang off it.
    assert "password_hash" not in user_payload
    assert "email" not in user_payload


async def test_an_email_can_only_be_used_once(api):
    await register(api)

    response = await api.post("/auth/register", json=ALICE)

    assert response.status_code == 409
    assert response.json()["detail"]["error"] == "email_taken"


async def test_a_short_password_is_refused(api):
    response = await api.post("/auth/register", json={**ALICE, "password": "short"})

    assert response.status_code == 422


async def test_joining_with_the_invite_code_lands_in_the_same_household(api, db_engine):
    alice = await register(api)

    response = await api.post(
        "/auth/join", json={**BOB, "invite_code": alice["invite_code"]}
    )

    assert response.status_code == 201
    bob = response.json()
    assert bob["household_id"] == alice["household_id"]
    assert bob["user_id"] != alice["user_id"]
    async with db_engine.connect() as connection:
        count = await connection.scalar(
            text("SELECT count(*) FROM users WHERE household_id = :h"),
            {"h": uuid.UUID(alice["household_id"])},
        )
    assert count == 2


async def test_the_invite_code_is_case_insensitive_and_trimmed(api):
    alice = await register(api)

    response = await api.post(
        "/auth/join",
        json={**BOB, "invite_code": f"  {alice['invite_code'].lower()}  "},
    )

    assert response.status_code == 201


async def test_whoever_joins_becomes_visible_to_whoever_invited(api):
    alice = await register(api)
    await api.post("/auth/join", json={**BOB, "invite_code": alice["invite_code"]})

    pulled = (await api.get("/sync/pull", params={"since": 0}, headers=bearer(alice))).json()
    names = [
        change["payload"]["display_name"]
        for change in pulled["changes"]
        if change["entity_type"] == "user"
    ]

    assert names == ["Alice", "Bob"]


async def test_an_unknown_invite_code_is_refused(api):
    await register(api)

    response = await api.post("/auth/join", json={**BOB, "invite_code": "ZZZZZZZZ"})

    assert response.status_code == 404
    assert response.json()["detail"]["error"] == "unknown_invite_code"


async def test_logging_in_returns_a_working_token(api):
    await register(api)

    response = await api.post(
        "/auth/login", json={"email": ALICE["email"], "password": ALICE["password"]}
    )

    assert response.status_code == 200
    body = response.json()
    me = await api.get("/auth/me", headers=bearer(body))
    assert me.status_code == 200
    assert me.json()["display_name"] == "Alice"


async def test_the_email_is_matched_without_regard_to_case(api):
    await register(api)

    response = await api.post(
        "/auth/login", json={"email": "ALICE@Example.COM ", "password": ALICE["password"]}
    )

    assert response.status_code == 200


@pytest.mark.parametrize(
    "credentials",
    [
        {"email": "alice@example.com", "password": "wrong password"},
        {"email": "nobody@example.com", "password": "correct horse battery"},
    ],
    ids=["wrong password", "no such account"],
)
async def test_a_failed_login_says_the_same_thing_either_way(api, credentials):
    """A different answer for an unknown address would be a way to find accounts."""
    await register(api)

    response = await api.post("/auth/login", json=credentials)

    assert response.status_code == 401
    assert response.json()["detail"] == {"error": "invalid_credentials"}


async def test_me_reports_the_identity_and_the_invite_code(api):
    alice = await register(api)

    body = (await api.get("/auth/me", headers=bearer(alice))).json()

    assert body == {
        "user_id": alice["user_id"],
        "household_id": alice["household_id"],
        "display_name": "Alice",
        "email": "alice@example.com",
        "invite_code": alice["invite_code"],
    }


@pytest.mark.parametrize("path", ["/auth/me", "/sync/pull"])
async def test_no_token_means_no_access(api, path):
    response = await api.get(path)

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


async def test_a_token_this_server_did_not_sign_is_refused(api):
    alice = await register(api)
    forged = jwt.encode(
        {
            "sub": alice["user_id"],
            "hh": alice["household_id"],
            "exp": int((datetime.now(UTC) + timedelta(days=1)).timestamp()),
        },
        "not the server's key, but a long enough one to encode with",
        algorithm="HS256",
    )

    response = await api.get("/auth/me", headers={"Authorization": f"Bearer {forged}"})

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "invalid_token"


async def test_an_expired_token_is_refused(api):
    alice = await register(api)
    stale = jwt.encode(
        {
            "sub": alice["user_id"],
            "hh": alice["household_id"],
            "exp": int((datetime.now(UTC) - timedelta(minutes=1)).timestamp()),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )

    response = await api.get("/auth/me", headers={"Authorization": f"Bearer {stale}"})

    assert response.status_code == 401


async def test_a_token_without_a_household_claim_is_refused(api):
    """Every claim the endpoints rely on has to be present, not defaulted."""
    incomplete = jwt.encode(
        {
            "sub": str(uuid.uuid4()),
            "exp": int((datetime.now(UTC) + timedelta(days=1)).timestamp()),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )

    response = await api.get("/auth/me", headers={"Authorization": f"Bearer {incomplete}"})

    assert response.status_code == 401


async def test_one_household_cannot_read_another_with_its_own_token(api):
    from tests.conftest import change, task_payload

    alice = await register(api)
    other = await register(api, email="stranger@example.com", household_name="Elsewhere")

    class AliceFamily:
        household_id = uuid.UUID(alice["household_id"])
        alice_id = uuid.UUID(alice["user_id"])

    await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(AliceFamily, title="Private"))]},
        headers=bearer(alice),
    )

    pulled = (await api.get("/sync/pull", params={"since": 0}, headers=bearer(other))).json()
    titles = [c["payload"].get("title") for c in pulled["changes"]]

    assert "Private" not in titles


async def test_the_household_comes_from_the_token_not_the_payload(api, db_engine):
    from tests.conftest import change, task_payload

    alice = await register(api)
    other = await register(api, email="stranger@example.com")

    class Trespass:
        household_id = uuid.UUID(alice["household_id"])
        alice_id = uuid.UUID(other["user_id"])

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(Trespass, title="Trespassing"))]},
        headers=bearer(other),
    )

    assert response.status_code == 200
    async with db_engine.connect() as connection:
        owner = await connection.scalar(
            text("SELECT household_id FROM tasks WHERE title = 'Trespassing'")
        )
    assert owner == uuid.UUID(other["household_id"])


async def test_the_password_hash_never_leaves_the_credentials_table(api, db_engine):
    alice = await register(api)

    async with db_engine.connect() as connection:
        stored = await connection.scalar(text("SELECT password_hash FROM credentials"))
        user_columns = [
            row[0]
            for row in await connection.execute(
                text(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_name = 'users'"
                )
            )
        ]

    assert stored.startswith("$argon2id$")
    assert ALICE["password"] not in stored
    assert "password_hash" not in user_columns
    assert "email" not in user_columns
    # And nothing about it comes back over the wire.
    assert "password" not in (await api.get("/auth/me", headers=bearer(alice))).text


async def test_a_token_that_never_expires_is_refused(api):
    """An absent `exp` is not the same as a distant one.

    A JWT library only checks an expiry that is there, so a token minted without
    one would be valid forever. The claim has to be required, not merely
    validated when present.
    """
    alice = await register(api)
    endless = jwt.encode(
        {"sub": alice["user_id"], "hh": alice["household_id"]},
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )

    response = await api.get("/auth/me", headers={"Authorization": f"Bearer {endless}"})

    assert response.status_code == 401
