# App target

One file, on purpose.

Everything else lives in `../FamilyCalendarKit`:

* `FamilyCalendarKit` — database, records, repositories, sync.
* `FamilyCalendarUI` — views, view models, and the launch path
  (`App/AppRootView.swift`, `App/SignInView.swift`, `App/AppDelegate.swift`).

A file added to an Xcode project by hand can quietly become a *copy* of the one
in the repository, and then stop matching it — changes land in git and never
reach the build, which is maddening to diagnose. A local Swift package is always
referenced by path, never copied, so keeping the code there removes the problem
rather than documenting it.

`FamilyCalendarApp.swift` is the exception that cannot be avoided: `@main` has
to be in the app target. It is twenty-odd lines and should never need changing.

Set `ServerAddress.url` in its `init()` to point at the server.
