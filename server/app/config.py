"""Application settings."""

from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict

DEV_JWT_SECRET = "dev-insecure-secret-change-me-before-deploying"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FC_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://fc:fc@localhost:5432/family_calendar"

    #: Signs the access tokens. Set FC_JWT_SECRET in any real deployment — the
    #: default is a development placeholder and the server says so on startup.
    jwt_secret: str = DEV_JWT_SECRET
    jwt_algorithm: str = "HS256"

    #: Tokens are long-lived on purpose. A device may be offline for a month and
    #: must still be able to push when it reconnects; an expiry it can hit while
    #: offline turns a sync into a login prompt at the worst possible moment.
    jwt_ttl_days: int = 365


settings = Settings()
