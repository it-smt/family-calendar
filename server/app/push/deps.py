"""How the endpoints get hold of a push client.

Through a dependency rather than by constructing one, so a test can put
something else there — and so the "not configured" case is one place rather
than scattered through the endpoints.
"""

from __future__ import annotations

from app.push.apns import APNsClient


def get_push_client() -> APNsClient | None:
    """None when push is not configured, which is the normal state in
    development and must break nothing."""
    return APNsClient.from_settings()
