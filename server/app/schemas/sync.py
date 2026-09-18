"""The sync wire format. Two endpoints, four shapes."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field

#: One push is one transaction. A device that has been offline for a month
#: sends several of them rather than one enormous one.
MAX_PUSH_BATCH = 1000


class ChangeIn(BaseModel):
    entity_type: str
    payload: dict[str, Any]


class PushRequest(BaseModel):
    changes: list[ChangeIn] = Field(default_factory=list, max_length=MAX_PUSH_BATCH)


class ChangeOut(BaseModel):
    seq: int | None = None
    entity_type: str
    entity_id: str
    payload: dict[str, Any]


class PushResponse(BaseModel):
    #: The rows that actually changed, in the server's version of them. A row
    #: the server rejected as stale is absent — the device applies what comes
    #: back and clears its dirty flags either way, because both mean "the server
    #: and I now agree".
    applied: list[ChangeOut]
    #: The highest sequence number this push wrote. Informational only: moving
    #: the pull cursor here would skip whatever the partner committed in the
    #: meantime.
    server_cursor: int


class PullResponse(BaseModel):
    changes: list[ChangeOut]
    cursor: int
    has_more: bool
