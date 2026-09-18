-- Schema v5. Keeping step with the server.
--
-- The push token moved out of `users` and into a table of its own on the
-- server. A token belongs to a device rather than to a person, and `users` is a
-- synchronised row: last-write-wins compares whole rows, so the other phone —
-- editing a display name from a copy it fetched an hour ago — would push back
-- the token it had then and silently unregister a device it knows nothing
-- about. A value only one device can know has no business travelling through a
-- shared row.

ALTER TABLE users DROP COLUMN apns_token;
