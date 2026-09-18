"""The sync transport.

The device database is the source of truth. This server moves changes between
two of them and assigns the sequence numbers that order those changes.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.config import DEV_JWT_SECRET, settings

from app.api import auth, sync
from app.db.session import engine


log = logging.getLogger("app")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if settings.jwt_secret == DEV_JWT_SECRET:
        log.warning(
            "FC_JWT_SECRET is unset, so tokens are signed with the development "
            "key that ships in the source. Set it before this server is "
            "reachable by anything but you."
        )
    yield
    await engine.dispose()


app = FastAPI(title="family-calendar sync", version="0.1.0", lifespan=lifespan)
app.include_router(auth.router)
app.include_router(sync.router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
