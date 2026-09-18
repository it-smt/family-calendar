-- Schema v1. Mirrors the Postgres schema in server/alembic/versions/0001.
--
-- Differences from the server, all of them deliberate:
--   * `dirty` exists here only — it is the outbox flag.
--   * `change_log` does not exist here; `sync_state` holds the pull cursor.
--   * UUIDs are TEXT (uppercase), timestamps are ISO-8601 strings, booleans
--     are 0/1, and JSON columns hold JSON text. This is what makes a change row
--     move between the two databases without translation.
--   * Enums are TEXT with a CHECK. Unlike the server, the device may constrain
--     its own writes freely: a rejected write here is a bug caught at the
--     source, not a push that can never succeed.

CREATE TABLE households (
    id          TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL,
    invite_code TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    updated_by  TEXT,
    deleted_at  TEXT,
    dirty       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX uq_households_invite_code_live
    ON households (invite_code) WHERE deleted_at IS NULL;
CREATE INDEX ix_households_dirty ON households (dirty) WHERE dirty = 1;

CREATE TABLE users (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    display_name TEXT NOT NULL,
    color        TEXT NOT NULL DEFAULT '#3478F6',
    apns_token   TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_users_household_id_updated_at ON users (household_id, updated_at);
CREATE INDEX ix_users_dirty ON users (dirty) WHERE dirty = 1;

CREATE TABLE categories (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    name         TEXT NOT NULL,
    color_hex    TEXT NOT NULL DEFAULT '#8E8E93',
    icon         TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_categories_household_id_updated_at ON categories (household_id, updated_at);
CREATE INDEX ix_categories_dirty ON categories (dirty) WHERE dirty = 1;

CREATE TABLE packing_templates (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    name         TEXT NOT NULL,
    items        TEXT NOT NULL DEFAULT '[]',
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_packing_templates_household_id_updated_at
    ON packing_templates (household_id, updated_at);
CREATE INDEX ix_packing_templates_dirty ON packing_templates (dirty) WHERE dirty = 1;

CREATE TABLE tasks (
    id                    TEXT PRIMARY KEY NOT NULL,
    household_id          TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    title                 TEXT NOT NULL,
    notes                 TEXT,
    starts_at             TEXT,
    duration_minutes      INTEGER,
    is_all_day            INTEGER NOT NULL DEFAULT 0,
    location_name         TEXT,
    latitude              REAL,
    longitude             REAL,
    rrule                 TEXT,
    recurrence_exceptions TEXT NOT NULL DEFAULT '[]',
    assignee_id           TEXT REFERENCES users (id) DEFERRABLE INITIALLY DEFERRED,
    created_by            TEXT NOT NULL REFERENCES users (id) DEFERRABLE INITIALLY DEFERRED,
    category_id           TEXT REFERENCES categories (id) DEFERRABLE INITIALLY DEFERRED,
    completed_at          TEXT,
    travel_mode           TEXT NOT NULL DEFAULT 'none'
                          CHECK (travel_mode IN ('none', 'walking', 'driving', 'transit')),
    created_at            TEXT NOT NULL,
    updated_at            TEXT NOT NULL,
    updated_by            TEXT,
    deleted_at            TEXT,
    dirty                 INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_tasks_household_id_starts_at ON tasks (household_id, starts_at);
CREATE INDEX ix_tasks_household_id_updated_at ON tasks (household_id, updated_at);
CREATE INDEX ix_tasks_assignee_id ON tasks (assignee_id);
CREATE INDEX ix_tasks_category_id ON tasks (category_id);
CREATE INDEX ix_tasks_dirty ON tasks (dirty) WHERE dirty = 1;

CREATE TABLE reminders (
    id             TEXT PRIMARY KEY NOT NULL,
    household_id   TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    task_id        TEXT NOT NULL REFERENCES tasks (id) DEFERRABLE INITIALLY DEFERRED,
    offset_minutes INTEGER NOT NULL DEFAULT 0,
    kind           TEXT NOT NULL DEFAULT 'fixed'
                   CHECK (kind IN ('fixed', 'leave_time', 'geo')),
    latitude       REAL,
    longitude      REAL,
    radius_meters  REAL,
    on_enter       INTEGER NOT NULL DEFAULT 0,
    on_exit        INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL,
    updated_by     TEXT,
    deleted_at     TEXT,
    dirty          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_reminders_task_id ON reminders (task_id);
CREATE INDEX ix_reminders_household_id_updated_at ON reminders (household_id, updated_at);
CREATE INDEX ix_reminders_dirty ON reminders (dirty) WHERE dirty = 1;

CREATE TABLE subtasks (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    task_id      TEXT NOT NULL REFERENCES tasks (id) DEFERRABLE INITIALLY DEFERRED,
    title        TEXT NOT NULL,
    is_done      INTEGER NOT NULL DEFAULT 0,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_subtasks_task_id_sort_order ON subtasks (task_id, sort_order);
CREATE INDEX ix_subtasks_household_id_updated_at ON subtasks (household_id, updated_at);
CREATE INDEX ix_subtasks_dirty ON subtasks (dirty) WHERE dirty = 1;

CREATE TABLE shopping_items (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    title        TEXT NOT NULL,
    quantity     TEXT,
    is_bought    INTEGER NOT NULL DEFAULT 0,
    category_id  TEXT REFERENCES categories (id) DEFERRABLE INITIALLY DEFERRED,
    added_by     TEXT NOT NULL REFERENCES users (id) DEFERRABLE INITIALLY DEFERRED,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_shopping_items_household_id_updated_at
    ON shopping_items (household_id, updated_at);
CREATE INDEX ix_shopping_items_category_id ON shopping_items (category_id);
CREATE INDEX ix_shopping_items_dirty ON shopping_items (dirty) WHERE dirty = 1;

CREATE TABLE activity_entries (
    id           TEXT PRIMARY KEY NOT NULL,
    household_id TEXT NOT NULL REFERENCES households (id) DEFERRABLE INITIALLY DEFERRED,
    actor_id     TEXT NOT NULL REFERENCES users (id) DEFERRABLE INITIALLY DEFERRED,
    entity_type  TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    action       TEXT NOT NULL,
    summary      TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    updated_by   TEXT,
    deleted_at   TEXT,
    dirty        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_activity_entries_household_id_created_at
    ON activity_entries (household_id, created_at);
CREATE INDEX ix_activity_entries_entity_type_entity_id
    ON activity_entries (entity_type, entity_id);
CREATE INDEX ix_activity_entries_dirty ON activity_entries (dirty) WHERE dirty = 1;

-- Device-local bookkeeping. Never synchronised, never pushed.
CREATE TABLE sync_state (
    id             INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
    pull_cursor    INTEGER NOT NULL DEFAULT 0,
    last_synced_at TEXT
);
INSERT INTO sync_state (id, pull_cursor) VALUES (1, 0);
