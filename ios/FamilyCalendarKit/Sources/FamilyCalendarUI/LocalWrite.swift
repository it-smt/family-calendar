import FamilyCalendarKit
import Foundation
import OSLog

/// Runs a write to the device's own database, and says so in the log if it
/// fails.
///
/// The interface deliberately says nothing when the *network* fails — that is
/// the whole design. A write to the local database is a different animal: it
/// cannot fail for any reason outside this app, so a failure is a bug. Swallowed
/// with `try?`, such a bug looks exactly like nothing having been typed: the
/// list simply does not grow, with no error anywhere. That is precisely how a
/// missing household row made every single screen refuse to add anything.
///
/// Nothing is shown to the person, because there is nothing they could do about
/// it. But it leaves a line in the log, which is the difference between a bug
/// that can be found and one that cannot.
func localWrite(_ what: StaticString, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        Log.database.error(
            "\(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
    }
}
