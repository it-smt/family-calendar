# Getting this running in Xcode

There is no `.xcodeproj` in the repository, because a project file is generated
noise that is better made once on the machine that will build it. This is how to
make it, in the order that keeps each step checkable.

Nothing here has been run: there is no Swift toolchain in the environment this
was written in, so expect compiler errors at step 7 and treat them as normal.

## What you need

* Xcode 16 or newer.
* The server running: `cd server && docker compose up --build`.
* A clone of this repository. The Xcode project goes **inside** it, so the
  package path stays relative and git sees your changes.

## 1. Put the project in the repository

If you made `FamilyCalendar` somewhere else, move the whole folder (the one
containing `FamilyCalendar.xcodeproj`) to the root of this repository:

```
family-calendar/
├── FamilyCalendar/            ← your Xcode project
│   ├── FamilyCalendar.xcodeproj
│   └── FamilyCalendar/        ← the group Xcode made
├── ios/
│   ├── FamilyCalendarKit/     ← the package
│   ├── FamilyCalendar/        ← the app's source, two files
│   └── FamilyCalendarWidget/  ← the widget's source, three files
└── server/
```

## 2. Delete the two files Xcode generated

In the `FamilyCalendar` group, delete **`ContentView.swift`** and
**`FamilyCalendarApp.swift`** (Move to Trash).

This matters: `ios/FamilyCalendar/FamilyCalendarApp.swift` also declares
`@main`, and two of those in one target is a compile error with a confusing
message.

Keep `Assets.xcassets`.

## 3. Add the package

**File → Add Package Dependencies… → Add Local…**, choose
`ios/FamilyCalendarKit`, then **Add Package**.

Xcode asks which products to add to which target. Add both to
**FamilyCalendar**:

* `FamilyCalendarKit`
* `FamilyCalendarUI`

The first build fetches GRDB, so it needs a network and takes a minute.

## 4. Add the app's one source file

Drag `ios/FamilyCalendar/FamilyCalendarApp.swift` into the `FamilyCalendar`
group, and tick **FamilyCalendar** under "Add to targets".

That is the only file the app target needs: `@main` has to live there, and
everything else is in the package. This is deliberate — a hand-added file can
become a *copy* of the one in the repository and then stop matching it, so
changes land in git and never reach the build. A local package is always
referenced by path.

If you added it as a copy earlier and it still sets `ServerAddress.url`, the
build will now fail to compile: the address moved into the package and is set
from the sign-in screen instead. Replace your copy with the current file — it
is nine lines and sets nothing.

If the dialog offers **Copy** or **Move**, either is fine for this one file,
because it should never change again. If you would rather it stay linked to the
repository, use **File → Add Files to "FamilyCalendar"…** from the menu instead
of dragging: that sheet has the **"Copy items if needed"** checkbox, and leaving
it unticked references the file where it is.

## 5. Set the deployment target

Target **FamilyCalendar → General → Minimum Deployments → iOS 17.0**.

The package declares iOS 17, so anything lower fails to resolve with a message
about platform requirements rather than about this.

## 6. Let the app talk to your server

The address is not compiled in. On first launch the sign-in screen has a
**Другой сервер** line; what you type there is kept on that device and shown
afterwards in **Настройки → Этот телефон**.

Three ways to fill it in, in the order you will want them:

* **Simulator, server on this Mac.** Leave it alone. The default is
  `http://localhost:8000`, and the simulator shares the Mac's network.
* **A real phone, server on this Mac.** Type the Mac's address on the network,
  `http://192.168.1.x:8000`. Plain HTTP needs an App Transport Security
  exception — target **FamilyCalendar → Info**, add **App Transport Security
  Settings → Allow Arbitrary Loads** = `YES` while you are testing, and take it
  out again before anyone else uses this.
* **A deployed server.** Type the domain: `calendar.example.com`. HTTPS is
  assumed if you leave the scheme off, and no exception is needed.
  `server/README.md` has how to put one up.

A build that already knows where it is going can skip the typing: add
`FCServerURL` to the app's Info.plist with the full address. What was typed on
the device wins over it, so a phone can still be pointed somewhere else without
a new build.

## 7. Build

⌘B. **Expect errors.** Around four thousand lines of Swift in this repository
have never been near a compiler; the logic behind them is tested, the syntax is
not.

They will mostly be small: a wrong argument label, a renamed GRDB API, an
`import` missing. Send me the first batch and I will work through them.

Build the app alone first. Leave the widget until this compiles.

## 8. Run it

⌘R. You should get the sign-in screen.

* **Start a household** with any email and a password of eight characters or
  more. This is the one screen that needs the server.
* Add a task. It is saved before anything touches the network.
* Turn off Wi-Fi and keep using it — that is the point of the whole thing. The
  mark in the toolbar counts what the other phone has not seen yet.

To watch two phones converge, run a second simulator (**Product → Destination**)
and **Join** with the invite code from **Настройки**.

[`CHECK-TOGETHER.md`](CHECK-TOGETHER.md) is the half-hour of it worth doing by
hand: what two people editing the same task offline actually do to each other,
and what the app is supposed to say about it. The tests cover the protocol; that
covers the app.

## Later: the widget

The widget needs the App Group, which is what lets two processes open one
database file.

1. **File → New → Target → Widget Extension**, name it `FamilyCalendarWidget`,
   untick "Include Live Activity" and "Include Configuration Intent". The
   repository has both already — `LeaveTimeLiveActivity.swift` is the live
   activity — and Xcode's versions would only have to be deleted again.
2. Delete the files it generates, and add `ios/FamilyCalendarWidget/*.swift` the
   same way as step 4, with target **FamilyCalendarWidgetExtension** ticked.
   Three files: `FamilyCalendarWidget.swift`, `WidgetEntryView.swift`,
   `LeaveTimeLiveActivity.swift`.
3. Add `FamilyCalendarKit` to that target's frameworks (**General → Frameworks
   and Libraries → +**). Not `FamilyCalendarUI`: the widget draws its own views
   and has no business with the app's screens.
4. **Signing & Capabilities → + Capability → App Groups** on *both* targets, and
   add `group.com.example.familycalendar` to each.
5. On the **FamilyCalendar** target, **Info → + → `Supports Live Activities`** =
   `YES` (`NSSupportsLiveActivities`). Without it the "when to leave" live
   activity never starts, and nothing says so — the system simply refuses and
   the app has no way to tell that from "no route to show".

If App Groups will not turn on — a free Apple account often cannot — the app
still works completely. It notices, puts the database in its own container, and
says so on the Setup tab. Only the widget goes without, because a second process
has nowhere else to look.

## Later: push notifications

Only needed to make the other phone find out immediately rather than on its next
launch. It needs a paid developer account for the APNs key, and
`server/README.md` has the environment variables. Everything synchronises
without it.
