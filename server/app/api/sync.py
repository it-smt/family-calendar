"""The whole API: pull changes, push changes. No REST CRUD anywhere."""

from __future__ import annotations

import logging
from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import CurrentIdentity
from app.db.session import get_session
from app.schemas.sync import ChangeOut, PullResponse, PushRequest, PushResponse
from app.sync.apply import AppliedChange, apply_push, read_changes
from app.sync.registry import WRITABLE_ENTITY_TYPES, spec_for
from app.sync.retention import prune_activity
from app.sync.schemas import validate_payload
from app.push.apns import APNsClient
from app.push.deps import get_push_client
from app.push.wake import wake_household
from app.sync.serialization import to_wire

log = logging.getLogger("app.sync")

router = APIRouter(prefix="/sync", tags=["sync"])

Session = Annotated[AsyncSession, Depends(get_session)]
PushClient = Annotated["APNsClient | None", Depends(get_push_client)]

DEFAULT_PAGE = 500
MAX_PAGE = 2000


def _as_change_out(change: AppliedChange) -> ChangeOut:
    return ChangeOut(
        seq=change.seq,
        entity_type=change.entity_type,
        entity_id=to_wire(change.entity_id),
        payload=change.payload,
    )


@router.get("/pull", response_model=PullResponse)
async def pull(
    identity: CurrentIdentity,
    session: Session,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=MAX_PAGE)] = DEFAULT_PAGE,
) -> PullResponse:
    page = await read_changes(session, identity.household_id, since=since, limit=limit)
    return PullResponse(
        changes=[_as_change_out(change) for change in page.changes],
        cursor=page.cursor,
        has_more=page.has_more,
    )


@router.post("/push", response_model=PushResponse)
async def push(
    request: PushRequest,
    identity: CurrentIdentity,
    session: Session,
    background: BackgroundTasks,
    push_client: PushClient,
) -> PushResponse:
    prepared: list[tuple[str, dict[str, Any]]] = []

    for index, change in enumerate(request.changes):
        spec = spec_for(change.entity_type)
        if spec is None or not spec.writable:
            raise HTTPException(
                status_code=422,
                detail={
                    "error": "unknown_entity_type",
                    "index": index,
                    "entity_type": change.entity_type,
                    "writable": list(WRITABLE_ENTITY_TYPES),
                },
            )
        try:
            values = validate_payload(change.entity_type, change.payload)
        except ValidationError as error:
            raise HTTPException(
                status_code=422,
                detail={
                    "error": "invalid_payload",
                    "index": index,
                    "entity_type": change.entity_type,
                    "problems": error.errors(include_url=False),
                },
            ) from error

        sent_household = values.get("household_id")
        if sent_household is not None and sent_household != identity.household_id:
            # Overwritten rather than rejected: a rejected push is retried
            # forever by a device that has already committed the change locally.
            log.warning(
                "push carried a foreign household_id; overriding",
                extra={"entity_type": change.entity_type, "sent": str(sent_household)},
            )

        prepared.append((change.entity_type, values))

    # One transaction for the whole batch: all of it lands or none of it does.
    # The foreign keys are deferred, so a row pointing at something that does
    # not exist only surfaces here, at COMMIT, once every row has been written.
    try:
        async with session.begin():
            result = await apply_push(
                session,
                household_id=identity.household_id,
                user_id=identity.user_id,
                changes=prepared,
            )
            # The household is already locked and the transaction already open,
            # so the feed is trimmed here rather than by a job nobody runs.
            await prune_activity(session, identity.household_id)
    except IntegrityError as error:
        constraint = getattr(getattr(error.orig, "__cause__", None), "constraint_name", None)
        log.warning("push rejected: %s", constraint or error.orig)
        raise HTTPException(
            status_code=422,
            detail={
                "error": "missing_reference",
                "constraint": constraint,
                "hint": "push the rows this batch points at in the same batch",
            },
        ) from error

    # Only when something actually changed. Waking the other phone over a
    # no-op would have the two of them taking turns waking each other for
    # nothing, the same way an advancing cursor would.
    if result.applied:
        # After the response, not before it: the push is finished the moment it
        # is committed, and nothing the device is waiting for depends on Apple.
        background.add_task(
            wake_household,
            session,
            push_client,
            identity.household_id,
            identity.user_id,
        )

    return PushResponse(
        applied=[_as_change_out(change) for change in result.applied],
        server_cursor=result.server_cursor,
    )
