-- Schema v7. Mirrors server/alembic/versions/0004.
--
-- A repeating task is one row and a rule, so there is nowhere on it to record
-- that this Tuesday is done. Ticking one off used to strike it out of the rule
-- instead: the line vanished rather than going grey, and "пропустить" and
-- "сделано" became the same thing.
--
-- One row per completed instant. No unique index on (task_id, occurrence): two
-- phones ticking the same Tuesday while both are offline would each make a row,
-- and a constraint the device can violate is worse than a duplicate — the push
-- would be rejected for ever by a device that has already committed the change.
-- Any live row means done; unticking tombstones all of them.

CREATE TABLE occurrence_completions (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    task_id      TEXT NOT NULL REFERENCES tasks (id) DEFERRABLE INITIALLY DEFERRED,
    occurrence   TEXT NOT NULL,
    completed_by TEXT REFERENCES users (id) DEFERRABLE INITIALLY DEFERRED,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_occurrence_completions_task_id_occurrence
    ON occurrence_completions (task_id, occurrence);
CREATE INDEX ix_occurrence_completions_household_id_updated_at
    ON occurrence_completions (household_id, updated_at);
CREATE INDEX ix_occurrence_completions_dirty
    ON occurrence_completions (dirty) WHERE dirty = 1;
