"""Registration, joining a household, logging in.

As simple as it can be while still being real: an email and a password per
person, argon2 for the hash, one signed token. No email confirmation, no
password reset, no refresh flow — this is a calendar for two people who can
reinstall each other's app by hand if it comes to that.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import CurrentIdentity
from app.auth.invites import new_invite_code
from app.auth.passwords import hash_password, verify_absent_user, verify_password
from app.auth.tokens import Identity, issue_token
from app.db.models import Credential, Device, Household, User
from app.db.session import get_session
from app.schemas.auth import (
    AuthResponse,
    DeviceRequest,
    JoinRequest,
    LoginRequest,
    MeResponse,
    RegisterRequest,
)
from app.sync.apply import lock_household, record_changes
from app.sync.serialization import row_to_payload, to_wire

router = APIRouter(prefix="/auth", tags=["auth"])

Session = Annotated[AsyncSession, Depends(get_session)]

INVALID_CREDENTIALS = HTTPException(
    status_code=401,
    detail={"error": "invalid_credentials"},
    headers={"WWW-Authenticate": "Bearer"},
)

#: Invite codes are random, so a collision is a lottery win rather than a bug.
#: Retrying a couple of times costs nothing and removes the failure mode.
INVITE_CODE_ATTEMPTS = 5


def _normalise_email(email: str) -> str:
    return email.strip().lower()


async def _email_is_taken(session: AsyncSession, email: str) -> bool:
    return (
        await session.scalar(select(Credential.user_id).where(Credential.email == email))
    ) is not None


async def _insert_user(
    session: AsyncSession,
    *,
    household_id: uuid.UUID,
    display_name: str,
    email: str,
    password: str,
) -> Any:
    user_id = uuid.uuid4()
    now = datetime.now(UTC)
    user_row = (
        await session.execute(
            User.__table__.insert()
            .values(
                id=user_id,
                household_id=household_id,
                display_name=display_name,
                created_at=now,
                updated_at=now,
                updated_by=user_id,
            )
            .returning(User.__table__)
        )
    ).one()
    await session.execute(
        Credential.__table__.insert().values(
            user_id=user_id,
            email=email,
            password_hash=hash_password(password),
            created_at=now,
            updated_at=now,
        )
    )
    return user_row


def _auth_response(
    identity: Identity, invite_code: str
) -> AuthResponse:
    token, expires_at = issue_token(identity)
    return AuthResponse(
        access_token=token,
        expires_at=to_wire(expires_at),
        user_id=to_wire(identity.user_id),
        household_id=to_wire(identity.household_id),
        invite_code=invite_code,
    )


@router.post("/register", response_model=AuthResponse, status_code=201)
async def register(body: RegisterRequest, session: Session) -> AuthResponse:
    email = _normalise_email(body.email)

    async with session.begin():
        if await _email_is_taken(session, email):
            raise HTTPException(status_code=409, detail={"error": "email_taken"})

        household_id = uuid.uuid4()
        now = datetime.now(UTC)
        for attempt in range(INVITE_CODE_ATTEMPTS):
            code = new_invite_code()
            taken = await session.scalar(
                select(Household.id).where(
                    Household.invite_code == code, Household.deleted_at.is_(None)
                )
            )
            if taken is None:
                break
        else:  # pragma: no cover - would need five collisions in a row
            raise HTTPException(status_code=503, detail={"error": "no_invite_code"})

        household_row = (
            await session.execute(
                Household.__table__.insert()
                .values(
                    id=household_id,
                    name=body.household_name,
                    invite_code=code,
                    created_at=now,
                    updated_at=now,
                )
                .returning(Household.__table__)
            )
        ).one()

        user_row = await _insert_user(
            session,
            household_id=household_id,
            display_name=body.display_name,
            email=email,
            password=body.password,
        )

        # Both rows go into the change log, or the other device would join the
        # household and never learn who is already in it.
        await record_changes(
            session,
            household_id,
            [
                ("household", household_id, row_to_payload(household_row)),
                ("user", user_row._mapping["id"], row_to_payload(user_row)),
            ],
        )

    return _auth_response(
        Identity(household_id=household_id, user_id=user_row._mapping["id"]), code
    )


@router.post("/join", response_model=AuthResponse, status_code=201)
async def join(body: JoinRequest, session: Session) -> AuthResponse:
    email = _normalise_email(body.email)
    code = body.invite_code.strip().upper()

    async with session.begin():
        household = (
            await session.execute(
                select(Household.id, Household.invite_code).where(
                    Household.invite_code == code, Household.deleted_at.is_(None)
                )
            )
        ).one_or_none()
        if household is None:
            raise HTTPException(status_code=404, detail={"error": "unknown_invite_code"})

        if await _email_is_taken(session, email):
            raise HTTPException(status_code=409, detail={"error": "email_taken"})

        # A join writes to the change log, so it queues behind any push that is
        # already assigning sequence numbers in this household.
        await lock_household(session, household.id)

        user_row = await _insert_user(
            session,
            household_id=household.id,
            display_name=body.display_name,
            email=email,
            password=body.password,
        )
        await record_changes(
            session,
            household.id,
            [("user", user_row._mapping["id"], row_to_payload(user_row))],
        )

    return _auth_response(
        Identity(household_id=household.id, user_id=user_row._mapping["id"]),
        household.invite_code,
    )


@router.post("/login", response_model=AuthResponse)
async def login(body: LoginRequest, session: Session) -> AuthResponse:
    email = _normalise_email(body.email)

    row = (
        await session.execute(
            select(
                Credential.user_id,
                Credential.password_hash,
                User.household_id,
                Household.invite_code,
            )
            .join(User, User.id == Credential.user_id)
            .join(Household, Household.id == User.household_id)
            .where(Credential.email == email)
        )
    ).one_or_none()

    if row is None:
        # Same work, same answer: the endpoint does not reveal who has an account.
        verify_absent_user(body.password)
        raise INVALID_CREDENTIALS

    if not verify_password(row.password_hash, body.password):
        raise INVALID_CREDENTIALS

    return _auth_response(
        Identity(household_id=row.household_id, user_id=row.user_id), row.invite_code
    )


@router.get("/me", response_model=MeResponse)
async def me(identity: CurrentIdentity, session: Session) -> MeResponse:
    row = (
        await session.execute(
            select(
                User.id,
                User.household_id,
                User.display_name,
                Credential.email,
                Household.invite_code,
            )
            .join(Credential, Credential.user_id == User.id)
            .join(Household, Household.id == User.household_id)
            .where(User.id == identity.user_id)
        )
    ).one_or_none()

    if row is None:
        # A valid signature for a user who no longer exists.
        raise HTTPException(status_code=404, detail={"error": "unknown_user"})

    return MeResponse(
        user_id=to_wire(row.id),
        household_id=to_wire(row.household_id),
        display_name=row.display_name,
        email=row.email,
        invite_code=row.invite_code,
    )


@router.post("/device", status_code=204)
async def register_device(
    body: DeviceRequest, identity: CurrentIdentity, session: Session
) -> None:
    """Records where to send a wake-up.

    Idempotent by token: a device that re-registers the same token — which iOS
    asks it to do on every launch — updates the row rather than piling up
    duplicates. Registering again also clears a tombstone, because a reinstalled
    app gets the old token back often enough to matter.
    """
    now = datetime.now(UTC)
    async with session.begin():
        await session.execute(
            pg_insert(Device.__table__)
            .values(
                id=uuid.uuid4(),
                user_id=identity.user_id,
                token=body.token,
                platform=body.platform,
                created_at=now,
                updated_at=now,
            )
            .on_conflict_do_update(
                index_elements=[Device.__table__.c.token],
                set_={
                    "user_id": identity.user_id,
                    "platform": body.platform,
                    "updated_at": now,
                    "unregistered_at": None,
                },
            )
        )
