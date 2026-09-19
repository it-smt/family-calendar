"""What can be synchronised, and how each entity behaves.

One table drives everything: the wire names, which entities a device may push,
and which ones show up in the activity feed.
"""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import Table

from app.db.models import (
    ActivityEntry,
    Category,
    Household,
    OccurrenceCompletion,
    PackingTemplate,
    Reminder,
    ShoppingItem,
    Subtask,
    Task,
    User,
)


@dataclass(frozen=True)
class EntitySpec:
    entity_type: str
    table: Table
    #: Whether a device may push rows of this type.
    writable: bool = True
    #: Whether a change to this entity belongs in the activity feed.
    logs_activity: bool = False
    #: The column that carries a human-readable label for the feed.
    label_column: str | None = None


_SPECS = [
    EntitySpec("household", Household.__table__, label_column="name"),
    EntitySpec("user", User.__table__, label_column="display_name"),
    EntitySpec("category", Category.__table__, label_column="name"),
    EntitySpec("packing_template", PackingTemplate.__table__, label_column="name"),
    EntitySpec("task", Task.__table__, logs_activity=True, label_column="title"),
    EntitySpec("reminder", Reminder.__table__),
    EntitySpec("subtask", Subtask.__table__, logs_activity=True, label_column="title"),
    # One instant of a repeat, ticked off. No label of its own: the feed
    # already carries the task it belongs to.
    EntitySpec("occurrence_completion", OccurrenceCompletion.__table__),
    EntitySpec(
        "shopping_item", ShoppingItem.__table__, logs_activity=True, label_column="title"
    ),
    # Written by the server during push and pulled like everything else. A
    # device that pushed one back would start a loop, so it cannot.
    EntitySpec("activity_entry", ActivityEntry.__table__, writable=False),
]

SPECS_BY_TYPE = {spec.entity_type: spec for spec in _SPECS}
ENTITY_TYPES = tuple(SPECS_BY_TYPE)
WRITABLE_ENTITY_TYPES = tuple(spec.entity_type for spec in _SPECS if spec.writable)


def spec_for(entity_type: str) -> EntitySpec | None:
    return SPECS_BY_TYPE.get(entity_type)
