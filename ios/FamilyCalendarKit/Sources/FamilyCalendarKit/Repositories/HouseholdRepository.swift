import Foundation
import GRDB

/// The household row itself.
///
/// Read-only from here. The one thing the interface needs from it is the invite
/// code: without somewhere to read it out from, the second person has no way to
/// join, and a calendar for two stays a calendar for one.
public struct HouseholdRepository: Sendable {
    private let database: AppDatabase
    private let householdID: UUID

    public init(database: AppDatabase, householdID: UUID) {
        self.database = database
        self.householdID = householdID
    }

    /// Everyone in the household, by identifier.
    ///
    /// Two people, in practice. Enough of them to put a name on a task and a
    /// colour on a line in the feed.
    public func people() -> AsyncValueObservation<[UUID: User]> {
        ValueObservation
            .tracking { db in
                Dictionary(
                    uniqueKeysWithValues: try User
                        .filter(User.Columns.deletedAt == nil)
                        .fetchAll(db)
                        .map { ($0.id, $0) }
                )
            }
            .values(in: database.reader)
    }

    public func observe() -> AsyncValueObservation<Household?> {
        ValueObservation
            .tracking { [householdID] db in
                try Household
                    .filter(Household.Columns.id == householdID.storedKey)
                    .fetchOne(db)
            }
            .values(in: database.reader)
    }
}
