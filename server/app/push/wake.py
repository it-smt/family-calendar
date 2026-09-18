"""Who to wake, and what happens when a token stops working."""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Device, User

log = logging.getLogger("app.push")


async def tokens_to_wake(
    session: AsyncSession, household_id: uuid.UUID, actor_id: uuid.UUID
) -> list[str]:
    """Every live device in the household except the one that just pushed.

    Waking the sender's own device would have it pull back the change it just
    made — a round trip for nothing, and on a phone that is already awake.
    """
    result = await session.execute(
        select(Device.token)
        .join(User, User.id == Device.user_id)
        .where(
            User.household_id == household_id,
            Device.user_id != actor_id,
            Device.unregistered_at.is_(None),
        )
    )
    return [token for (token,) in result]


async def wake_household(
    session: AsyncSession,
    client,
    household_id: uuid.UUID,
    actor_id: uuid.UUID,
) -> None:
    """Tell the other phone something changed.

    Errors stop here. A push that does not arrive means the other device finds
    out on its next launch, foreground or network change — later, but never
    wrong. Nothing about correctness depends on this working.
    """
    if client is None:
        return

    try:
        tokens = await tokens_to_wake(session, household_id, actor_id)
        if not tokens:
            return

        result = await client.wake(tokens)

        if result.unregistered:
            # A device that has been deleted or reinstalled. Left in place with
            # a tombstone rather than removed, so a returning device can be told
            # apart from one that never existed.
            await session.execute(
                update(Device)
                .where(Device.token.in_(result.unregistered))
                .values(unregistered_at=datetime.now(UTC))
            )
            await session.commit()

        log.info(
            "woke %d device(s), %d gone, %d failed",
            len(result.delivered),
            len(result.unregistered),
            len(result.failed),
        )
    except Exception as error:  # noqa: BLE001 - nothing here may reach the caller
        log.warning("waking the household failed: %s", error)
