# App target

A shell. Everything else is in `../FamilyCalendarKit`:

* `FamilyCalendarKit` — database, records, repositories, sync.
* `FamilyCalendarUI` — views and view models.

To build, make an iOS app target in Xcode, add these two files to it, and add
the package at `../FamilyCalendarKit` as a local dependency.

The target needs the App Group entitlement
(`group.com.example.familycalendar`, and the same string in
`AppDatabase.appGroupIdentifier`) so the widget can read the database directly
in stage 7. Set `Configuration.serverURL` to wherever the server runs.
