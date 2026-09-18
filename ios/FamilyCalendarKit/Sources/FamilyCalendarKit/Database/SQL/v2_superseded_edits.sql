-- Schema v2. Device-only, never synchronised.
--
-- Last-write-wins compares whole rows, so when two people edit one task
-- offline the later stamp takes the other person's field with it — a field the
-- winner never touched. That is the protocol, and changing it means per-column
-- versions or a CRDT, which is a different application.
--
-- What it does not have to be is silent. When an arriving row replaces one this
-- person wrote, the version it replaced is kept here, so the app can say what
-- was lost and offer to put it back. Restoring is an ordinary local edit with a
-- newer stamp, so it wins the same way anything else does.

CREATE TABLE superseded_edits (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type   TEXT NOT NULL,
    entity_id     TEXT NOT NULL,
    -- JSON of the values this person had, and the ones that replaced them.
    mine          TEXT NOT NULL,
    theirs        TEXT NOT NULL,
    actor_id      TEXT,
    superseded_at TEXT NOT NULL,
    dismissed     INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX ix_superseded_edits_open
    ON superseded_edits (superseded_at) WHERE dismissed = 0;
CREATE INDEX ix_superseded_edits_entity
    ON superseded_edits (entity_type, entity_id);
