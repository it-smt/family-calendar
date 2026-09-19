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

    public func observe() -> AsyncValueObservation<Household?> {
        ValueObservation
            .tracking { [householdID] db in
                try Household
                    .filter(Household.Columns.id == householdID.uuidString)
                    .fetchOne(db)
            }
            .values(in: database.reader)
    }
}
