"""Background wake-ups.

The push carries nothing but "something changed". The device wakes, pulls, and
reads the change from the database as it always does — so a notification that
never arrives makes the other phone late, never wrong. These tests hold that
line: nothing about a sync may depend on Apple answering.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

import pytest
from sqlalchemy import text

from app.push.apns import ProviderToken, WakeResult
from app.push.wake import tokens_to_wake, wake_household
from tests.conftest import Family, change, task_payload


@dataclass
class FakeAPNs:
    """Stands in for Apple. Records what it was asked to do."""

    woken: list[list[str]] = field(default_factory=list)
    unregistered: list[str] = field(default_factory=list)
    explode: bool = False

    async def wake(self, tokens: list[str]) -> WakeResult:
        if self.explode:
            raise RuntimeError("APNs is having a day")
        self.woken.append(list(tokens))
        return WakeResult(
            delivered=[t for t in tokens if t not in self.unregistered],
            unregistered=[t for t in tokens if t in self.unregistered],
        )


async def register(api, family: Family, user_id: uuid.UUID, token: str) -> None:
    response = await api.post(
        "/auth/device", json={"token": token}, headers=family.headers(user_id)
    )
    assert response.status_code == 204, response.text


# --- who gets woken --------------------------------------------------------

async def test_the_other_phone_is_woken_and_your_own_is_not(api, family: Family, db_engine):
    """Waking the sender would have it pull back the change it just made."""
    await register(api, family, family.alice_id, "alice-token")
    await register(api, family, family.bob_id, "bob-token")

    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False)
    async with factory() as session:
        tokens = await tokens_to_wake(session, family.household_id, family.alice_id)

    assert tokens == ["bob-token"]


async def test_another_household_is_never_woken(api, family: Family, other_family: Family, db_engine):
    await register(api, family, family.bob_id, "ours-token")
    await register(api, other_family, other_family.bob_id, "theirs-token")

    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False)
    async with factory() as session:
        tokens = await tokens_to_wake(session, family.household_id, family.alice_id)

    assert tokens == ["ours-token"]


async def test_a_device_that_apple_says_is_gone_stops_being_woken(
    api, family: Family, db_engine
):
    await register(api, family, family.bob_id, "dead-token")

    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False)
    apns = FakeAPNs(unregistered=["dead-token"])

    async with factory() as session:
        await wake_household(session, apns, family.household_id, family.alice_id)

    async with factory() as session:
        remaining = await tokens_to_wake(session, family.household_id, family.alice_id)
    assert remaining == []


async def test_a_reinstalled_device_comes_back(api, family: Family, db_engine):
    """iOS hands the same token back often enough for this to matter."""
    await register(api, family, family.bob_id, "recycled")

    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False)
    async with factory() as session:
        await wake_household(
            session, FakeAPNs(unregistered=["recycled"]), family.household_id, family.alice_id
        )

    await register(api, family, family.bob_id, "recycled")

    async with factory() as session:
        assert await tokens_to_wake(session, family.household_id, family.alice_id) == ["recycled"]


# --- registration ----------------------------------------------------------

async def test_registering_the_same_token_twice_makes_one_row(api, family: Family, db_engine):
    """iOS asks the app to register on every launch."""
    await register(api, family, family.alice_id, "same-token")
    await register(api, family, family.alice_id, "same-token")

    async with db_engine.connect() as connection:
        count = await connection.scalar(text("SELECT count(*) FROM devices"))
    assert count == 1


async def test_a_token_needs_a_session(api):
    response = await api.post("/auth/device", json={"token": "no-token-here"})

    assert response.status_code == 401


async def test_the_push_token_is_not_part_of_the_synchronised_user(api, family: Family):
    """It belongs to a device, and `users` travels to both phones.

    Whole-row last-write-wins would let the partner's phone push back a stale
    copy and silently unregister a device it knows nothing about.
    """
    await register(api, family, family.alice_id, "private-token")

    pulled = (
        await api.get("/sync/pull", params={"since": 0}, headers=family.headers())
    ).json()

    for item in pulled["changes"]:
        assert "apns_token" not in item["payload"]
        assert "private-token" not in str(item["payload"])


# --- the push must not depend on any of this -------------------------------

async def test_a_push_succeeds_while_apple_is_down(api, family: Family, db_engine):
    """The sync is finished when it is committed. Apple is not part of that."""
    from sqlalchemy.ext.asyncio import async_sessionmaker

    await register(api, family, family.bob_id, "bob-token")
    factory = async_sessionmaker(db_engine, expire_on_commit=False)

    async with factory() as session:
        # wake_household swallows everything: a failure here would otherwise
        # surface as a failed push and a device retrying forever.
        await wake_household(
            session, FakeAPNs(explode=True), family.household_id, family.alice_id
        )

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(family))]},
        headers=family.headers(),
    )
    assert response.status_code == 200


async def test_nothing_is_sent_when_push_is_not_configured(family: Family, db_engine):
    """Development, and any deployment without a key, must work untouched."""
    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False)
    async with factory() as session:
        # `None` is what APNsClient.from_settings returns with no key.
        await wake_household(session, None, family.household_id, family.alice_id)


async def test_a_household_with_no_devices_sends_nothing(api, family: Family, db_engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_engine, expire_on_commit=False)
    apns = FakeAPNs()
    async with factory() as session:
        await wake_household(session, apns, family.household_id, family.alice_id)

    assert apns.woken == []


# --- the provider token ----------------------------------------------------

PRIVATE_KEY = """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----"""


def test_the_provider_token_is_reused_rather_than_minted_each_time():
    """Apple throttles a provider that mints one more than every 20 minutes."""
    token = ProviderToken(key_id="ABC123", team_id="TEAM123", private_key=PRIVATE_KEY)

    first = token.value(now=1_000_000)
    again = token.value(now=1_000_060)

    assert first == again


def test_the_provider_token_is_replaced_before_apple_stops_accepting_it():
    """Apple refuses one older than an hour."""
    token = ProviderToken(key_id="ABC123", team_id="TEAM123", private_key=PRIVATE_KEY)

    first = token.value(now=1_000_000)
    later = token.value(now=1_000_000 + 50 * 60)

    assert first != later


def test_the_provider_token_says_what_apple_expects():
    import jwt as pyjwt

    token = ProviderToken(key_id="ABC123", team_id="TEAM123", private_key=PRIVATE_KEY)
    value = token.value(now=1_700_000_000)

    assert pyjwt.get_unverified_header(value)["kid"] == "ABC123"
    assert pyjwt.get_unverified_header(value)["alg"] == "ES256"
    assert pyjwt.decode(value, options={"verify_signature": False})["iss"] == "TEAM123"


# --- through the endpoint --------------------------------------------------

@pytest.fixture
def apns(api):
    """Puts a fake Apple behind the push endpoint."""
    from app.main import app
    from app.push.deps import get_push_client

    fake = FakeAPNs()
    app.dependency_overrides[get_push_client] = lambda: fake
    yield fake
    app.dependency_overrides.pop(get_push_client, None)


async def test_a_real_change_wakes_the_other_phone(api, family: Family, apns):
    await register(api, family, family.bob_id, "bob-token")

    response = await api.post(
        "/sync/push",
        json={"changes": [change("task", task_payload(family))]},
        headers=family.headers(),
    )

    assert response.status_code == 200
    assert apns.woken == [["bob-token"]]


async def test_a_push_that_changes_nothing_wakes_nobody(api, family: Family, apns):
    """Otherwise two phones take turns waking each other over nothing.

    The same reasoning as the cursor: a no-op is not an event.
    """
    await register(api, family, family.bob_id, "bob-token")
    body = {"changes": [change("task", task_payload(family))]}

    await api.post("/sync/push", json=body, headers=family.headers())
    apns.woken.clear()

    second = await api.post("/sync/push", json=body, headers=family.headers())

    assert second.json()["applied"] == []
    assert apns.woken == []
