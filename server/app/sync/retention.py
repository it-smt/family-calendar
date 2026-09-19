"""How long the change feed is kept.

The feed is a record of who touched what, and every edit adds a row. Nothing
ever removed one, on either side — so after a year of ordinary use a household
carries thousands of rows that also travel between the two phones on every
fresh install. It is the one table in the schema that grows without bound and
is never read past its first page.

Both sides drop the same rows by the same rule — older than the cutoff — so
they converge without either having to tell the other. The device may delete
its copies outright because activity entries are never pushed; here, the entry
and the change-log row that carries it go together, or a device catching up
from zero would be handed rows whose entity no longer exists.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import ActivityEntry, ChangeLog

#: Long enough that "who moved the doctor" is still answerable weeks later,
#: short enough that the table stays a table rather than an archive.
RETENTION = timedelta(days=90)


async def prune_activity(
    session: AsyncSession, household_id: uuid.UUID, *, now: datetime | None = None
) -> int:
    """Drops this household's feed entries older than the cutoff.

    Called where the household is already locked and a transaction is already
    open, so it costs one pair of statements on a table with a handful of rows
    per day. Returns how many entries went, which is what the tests read.
    """
    cutoff = (now or datetime.now(UTC)) - RETENTION

    stale = (
        select(ActivityEntry.id)
        .where(
            ActivityEntry.household_id == household_id,
            ActivityEntry.created_at < cutoff,
        )
        .scalar_subquery()
    )

    # The log row first: while it exists, a device pulling from zero would be
    # handed an entry whose row has gone.
    await session.execute(
        delete(ChangeLog).where(
            ChangeLog.household_id == household_id,
            ChangeLog.entity_type == "activity_entry",
            ChangeLog.entity_id.in_(stale),
        )
    )
    result = await session.execute(
        delete(ActivityEntry).where(
            ActivityEntry.household_id == household_id,
            ActivityEntry.created_at < cutoff,
        )
    )
    return result.rowcount or 0
