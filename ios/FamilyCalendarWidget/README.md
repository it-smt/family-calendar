# Widget target

Another shell. The reading and the timeline live in `FamilyCalendarKit`
(`Widget/WidgetStore.swift`, `Widget/WidgetTimeline.swift`); these files are the
views and the WidgetKit plumbing.

In Xcode: add a Widget Extension target, put these two files in it, add the
package at `../FamilyCalendarKit` as a dependency, and give the target the same
App Group entitlement as the app (`group.com.example.familycalendar`). That
entitlement is the whole mechanism — it is what lets this process open the same
SQLite file the app writes to, with no app launch and no network.

Set `WidgetServer.url` to match the app's, so the tick from the
widget can try to push straight away. It works without it; the change just waits
for the app.
