"""Application settings.

The server is only a transport for changes between devices, so there is very
little to configure: a database URL and nothing else for now.
"""

from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FC_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://fc:fc@localhost:5432/family_calendar"


settings = Settings()
