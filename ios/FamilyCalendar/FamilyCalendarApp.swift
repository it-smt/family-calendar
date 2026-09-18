import FamilyCalendarUI
import SwiftUI

/// The whole of the app target.
///
/// Everything else is in the package, on purpose: a file here has to be added
/// to the Xcode project by hand, and a hand-added file is one that can quietly
/// become a copy and stop matching the repository. This one is small enough
/// that it should never need changing again.
@main
struct FamilyCalendarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // The simulator shares the Mac's network. For a real device, put the
        // Mac's address here and add an App Transport Security exception for
        // it — ios/SETUP.md has the details.
        ServerAddress.url = URL(string: "http://localhost:8000")!
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(delegate: delegate)
        }
    }
}
