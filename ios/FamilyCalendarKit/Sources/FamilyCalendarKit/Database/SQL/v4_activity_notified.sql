-- Schema v4. One device-only column on a synchronised table.
--
-- Delegation is only worth having if the person who asked finds out it is done.
-- The activity feed already carries "who did what" to both phones, so the
-- notice needs no new data — only a way to remember which entries this person
-- has already been told about.
--
-- Client-only, like `dirty`: the server neither sends it nor wants it, and the
-- other phone keeps its own answer, because the two phones are told about
-- different things.

ALTER TABLE activity_entries ADD COLUMN notified INTEGER NOT NULL DEFAULT 0;

CREATE INDEX ix_activity_entries_unnotified
    ON activity_entries (created_at) WHERE notified = 0;
