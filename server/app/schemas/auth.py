"""Auth wire format."""

from __future__ import annotations

from pydantic import BaseModel, EmailStr, Field

PASSWORD = Field(min_length=8, max_length=128)
DISPLAY_NAME = Field(min_length=1, max_length=100)


class RegisterRequest(BaseModel):
    """Starts a new household. The other person joins it with the invite code."""

    email: EmailStr
    password: str = PASSWORD
    display_name: str = DISPLAY_NAME
    household_name: str = Field(default="Home", min_length=1, max_length=100)


class JoinRequest(BaseModel):
    email: EmailStr
    password: str = PASSWORD
    display_name: str = DISPLAY_NAME
    invite_code: str = Field(min_length=4, max_length=16)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class AuthResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: str
    user_id: str
    household_id: str
    #: Shown to the other person so they can join. Never a secret in the sense a
    #: password is, but it is all someone needs to get into the household.
    invite_code: str


class MeResponse(BaseModel):
    user_id: str
    household_id: str
    display_name: str
    email: str
    invite_code: str


class DeviceRequest(BaseModel):
    """Where to send a background wake-up."""

    token: str = Field(min_length=8, max_length=200)
    platform: str = Field(default="ios", max_length=20)
