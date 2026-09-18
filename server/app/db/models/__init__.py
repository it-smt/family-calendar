"""Importing this package registers every table on `Base.metadata`."""

from app.db.base import Base
from app.db.models.activity import ActivityEntry
from app.db.models.catalog import Category, PackingTemplate, ShoppingItem
from app.db.models.change_log import ChangeLog
from app.db.models.credentials import Credential
from app.db.models.devices import Device
from app.db.models.household import Household, User
from app.db.models.task import Reminder, Subtask, Task

__all__ = [
    "ActivityEntry",
    "Base",
    "Category",
    "ChangeLog",
    "Credential",
    "Device",
    "Household",
    "PackingTemplate",
    "Reminder",
    "ShoppingItem",
    "Subtask",
    "Task",
    "User",
]
