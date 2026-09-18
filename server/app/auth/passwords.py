"""Password hashing.

Argon2id at the library's defaults. The parameters are not tuned: for a
household of two, the cost of a login is irrelevant and the defaults are the
choice least likely to be wrong.
"""

from __future__ import annotations

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

_hasher = PasswordHasher()

#: Verified against when no such user exists, so a wrong address and a wrong
#: password take the same time to fail and the endpoint does not become a way
#: to find out who has an account.
_ABSENT_USER_HASH = _hasher.hash("no such user")


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def verify_absent_user(password: str) -> None:
    """Spend the same work as a real verification, then fail anyway."""
    verify_password(_ABSENT_USER_HASH, password)
