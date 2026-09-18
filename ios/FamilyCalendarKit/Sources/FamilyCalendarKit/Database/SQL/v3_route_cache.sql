-- Schema v3. Device-only, never synchronised.
--
-- Routes the device has measured, kept so that "when to leave" still has an
-- answer with no network. A cached duration from an hour ago is a far better
-- guess than a straight line, and a straight line is a far better guess than
-- silence — which is what a calendar that waits for MapKit gives you on the
-- underground.
--
-- Not synchronised: a route is measured from where *this* phone is, and the
-- other phone is somewhere else.

CREATE TABLE route_cache (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    -- Both ends rounded to a grid, so standing a few doors down still hits the
    -- same entry. Exact coordinates would make the cache almost never match.
    origin_cell      TEXT NOT NULL,
    destination_cell TEXT NOT NULL,
    travel_mode      TEXT NOT NULL
                     CHECK (travel_mode IN ('walking', 'driving', 'transit')),
    duration_seconds REAL NOT NULL,
    distance_meters  REAL NOT NULL,
    -- Whether the measurement accounted for traffic, which is what decides how
    -- quickly it goes stale.
    with_traffic     INTEGER NOT NULL DEFAULT 0,
    measured_at      TEXT NOT NULL
);

CREATE UNIQUE INDEX uq_route_cache_leg
    ON route_cache (origin_cell, destination_cell, travel_mode);
CREATE INDEX ix_route_cache_measured_at ON route_cache (measured_at);

-- Where the phone was last seen. Device-local, like everything else here.
--
-- The widget needs it too: it works out when to leave from the same cache the
-- app does, in its own process, with no location permission of its own and no
-- way to ask.
ALTER TABLE sync_state ADD COLUMN last_latitude REAL;
ALTER TABLE sync_state ADD COLUMN last_longitude REAL;
