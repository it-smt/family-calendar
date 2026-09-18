"""Invite codes.

Eight characters from an alphabet with no look-alikes, because the code gets
read out loud or typed off another phone's screen.
"""

from __future__ import annotations

import secrets

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no I, L, O, 0, 1
LENGTH = 8


def new_invite_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(LENGTH))
