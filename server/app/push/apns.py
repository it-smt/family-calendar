"""Sending a background wake-up through APNs.

The push carries no content. It says "something changed" and nothing else; the
device wakes, pulls, and reads the change from the database like always. Putting
the data in the push would make delivery part of the protocol, and APNs does not
promise delivery — a dropped notification would become a lost change.
"""

from __future__ import annotations

import logging
import time
import uuid
from dataclasses import dataclass, field

import httpx
import jwt

from app.config import settings

log = logging.getLogger("app.push")

#: Apple rejects a provider token minted more often than once every 20 minutes
#: and stops accepting one older than an hour. Somewhere in between, so a busy
#: household never trips either end.
TOKEN_LIFETIME = 45 * 60

SANDBOX = "https://api.sandbox.push.apple.com"
PRODUCTION = "https://api.push.apple.com"


@dataclass
class ProviderToken:
    """The signed JWT Apple wants, cached because minting one per push is a
    documented way to get throttled."""

    key_id: str
    team_id: str
    private_key: str
    _value: str | None = field(default=None, repr=False)
    _issued_at: float = 0.0

    def value(self, now: float | None = None) -> str:
        now = now or time.time()
        if self._value is None or now - self._issued_at > TOKEN_LIFETIME:
            self._value = jwt.encode(
                {"iss": self.team_id, "iat": int(now)},
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.key_id},
            )
            self._issued_at = now
        return self._value


@dataclass
class WakeResult:
    delivered: list[str] = field(default_factory=list)
    #: Tokens Apple says are gone. The caller stops using them.
    unregistered: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)


class APNsClient:
    """Talks to Apple. Never raises at the caller: a push that cannot be sent is
    a slower sync, not a failure."""

    def __init__(
        self,
        *,
        key_id: str,
        team_id: str,
        private_key: str,
        topic: str,
        use_sandbox: bool = True,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self.topic = topic
        self.base_url = SANDBOX if use_sandbox else PRODUCTION
        self.provider_token = ProviderToken(
            key_id=key_id, team_id=team_id, private_key=private_key
        )
        self._client = client

    @classmethod
    def from_settings(cls) -> APNsClient | None:
        """None when push is not configured, which is the normal state in
        development and must not break anything."""
        if not (settings.apns_key_id and settings.apns_team_id and settings.apns_topic):
            return None
        try:
            private_key = settings.apns_private_key or (
                open(settings.apns_key_path).read() if settings.apns_key_path else ""
            )
        except OSError as error:
            log.warning("APNs key could not be read: %s", error)
            return None
        if not private_key:
            return None

        return cls(
            key_id=settings.apns_key_id,
            team_id=settings.apns_team_id,
            private_key=private_key,
            topic=settings.apns_topic,
            use_sandbox=settings.apns_use_sandbox,
        )

    async def wake(self, tokens: list[str]) -> WakeResult:
        result = WakeResult()
        if not tokens:
            return result

        client = self._client or httpx.AsyncClient(http2=True, timeout=10.0)
        try:
            for token in tokens:
                await self._send(client, token, result)
        finally:
            if self._client is None:
                await client.aclose()

        return result

    async def _send(self, client: httpx.AsyncClient, token: str, result: WakeResult) -> None:
        headers = {
            "authorization": f"bearer {self.provider_token.value()}",
            "apns-topic": self.topic,
            # A background push has to say so, or Apple will not deliver it to a
            # suspended app at all.
            "apns-push-type": "background",
            # Priority 10 on a background push is rejected outright.
            "apns-priority": "5",
            "apns-id": str(uuid.uuid4()),
        }
        # `content-available` and nothing else: no alert, no sound, no badge.
        # This wakes the app; it does not talk to the person.
        payload = {"aps": {"content-available": 1}}

        try:
            response = await client.post(
                f"{self.base_url}/3/device/{token}", json=payload, headers=headers
            )
        except httpx.HTTPError as error:
            log.info("push to %s… failed: %s", token[:8], error)
            result.failed.append(token)
            return

        if response.status_code == 200:
            result.delivered.append(token)
            return

        reason = ""
        try:
            reason = response.json().get("reason", "")
        except ValueError:
            pass

        # The device is gone for good. Anything else may work next time.
        if response.status_code == 410 or reason in {"BadDeviceToken", "Unregistered"}:
            log.info("token %s… is gone (%s)", token[:8], reason or response.status_code)
            result.unregistered.append(token)
        else:
            log.info("push rejected (%s %s)", response.status_code, reason)
            result.failed.append(token)
