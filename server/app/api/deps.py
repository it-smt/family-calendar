"""Who is calling.

The identity comes from a signed token and nothing else — no header a caller
can simply assert. `Identity` keeps the shape the sync endpoints already use,
so replacing the stage 2 placeholder touched nothing in `app/api/sync.py`.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.tokens import Identity, InvalidToken, decode_token

bearer_scheme = HTTPBearer(auto_error=False, description="Access token from /auth")

UNAUTHORIZED = HTTPException(
    status_code=401,
    detail={"error": "not_authenticated"},
    headers={"WWW-Authenticate": "Bearer"},
)


async def current_identity(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> Identity:
    if credentials is None or not credentials.credentials:
        raise UNAUTHORIZED
    try:
        return decode_token(credentials.credentials)
    except InvalidToken as error:
        raise HTTPException(
            status_code=401,
            detail={"error": "invalid_token", "reason": str(error)},
            headers={"WWW-Authenticate": "Bearer"},
        ) from error


CurrentIdentity = Annotated[Identity, Depends(current_identity)]

__all__ = ["CurrentIdentity", "Identity", "current_identity"]
