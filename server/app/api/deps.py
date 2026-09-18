"""Who is calling.

A placeholder until stage 3 replaces it with JWT. It is not authentication and
does not pretend to be: anyone who can reach the server can claim any identity.
The endpoints take the identity through this one dependency, so swapping in real
tokens does not touch them.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Header


@dataclass(frozen=True)
class Identity:
    household_id: uuid.UUID
    user_id: uuid.UUID


async def current_identity(
    x_household_id: Annotated[uuid.UUID, Header()],
    x_user_id: Annotated[uuid.UUID, Header()],
) -> Identity:
    return Identity(household_id=x_household_id, user_id=x_user_id)


CurrentIdentity = Annotated[Identity, Depends(current_identity)]
