-- Schema v6. Not a schema change: a repair.
--
-- The editor used to allow a task with no date at all — "Ко времени" off and
-- "Весь день" off left `starts_at` NULL. The day list asks for the tasks whose
-- `starts_at` falls inside the day, so such a row was saved successfully and
-- then shown by nothing, anywhere, ever. The editor no longer produces them;
-- this is for the ones already written.
--
-- They become all-day tasks on the day they were created. That is a guess, and
-- the only one available: a row with no date carries no better clue. The day is
-- read off `created_at`, which is UTC, so a task created late in the evening
-- east of Greenwich lands on the following day. Wrong by one is still findable,
-- and it can be moved; invisible cannot.
--
-- Marked dirty and stamped now, so the repair reaches the other phone by the
-- ordinary route rather than leaving the two databases disagreeing. Both
-- devices compute the same answer from the same `created_at`, so it does not
-- matter which of them gets there first.

UPDATE tasks
SET starts_at  = substr(created_at, 1, 10) || 'T00:00:00.000Z',
    is_all_day = 1,
    updated_at = MAX(updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    dirty      = 1
WHERE starts_at IS NULL
  AND deleted_at IS NULL;
