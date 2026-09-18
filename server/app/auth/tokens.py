"""Access tokens.

One long-lived bearer token, no refresh flow. A device may be offline for a
month; a token it can find expired on reconnect would turn a background sync
into a login prompt at the moment the user least expects one. For two people
sharing a calendar that trade is worth making, and it is the kind of thing to
revisit only if this ever stops being an app for two people.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt

from app.config import settings


@dataclass(frozen=True)
class Identity:
    household_id: uuid.UUID
    user_id: uuid.UUID


class InvalidToken(Exception):
    pass


def issue_token(identity: Identity, now: datetime | None = None) -> tuple[str, datetime]:
    issued_at = now or datetime.now(UTC)
    expires_at = issued_at + timedelta(days=settings.jwt_ttl_days)
    claims = {
        "sub": str(identity.user_id),
        "hh": str(identity.household_id),
        "iat": int(issued_at.timestamp()),
        "exp": int(expires_at.timestamp()),
    }
    token = jwt.encode(claims, settings.jwt_secret, algorithm=settings.jwt_algorithm)
    return token, expires_at


def decode_token(token: str) -> Identity:
    try:
        claims = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            options={"require": ["sub", "hh", "exp"]},
        )
        return Identity(
            household_id=uuid.UUID(claims["hh"]), user_id=uuid.UUID(claims["sub"])
        )
    except (jwt.InvalidTokenError, ValueError, KeyError) as error:
        raise InvalidToken(str(error)) from error
