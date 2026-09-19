import Foundation
import GRDB
import OSLog

/// The two rows every other row points at.
///
/// Every table in the schema carries `household_id NOT NULL REFERENCES
/// households (id)`, and tasks and shopping items also point at a user. With
/// foreign keys on — and they are on — a device whose `households` and `users`
/// tables are empty cannot insert anything at all: the first task, the first
/// category, the first item on the shopping list all fail with
/// `FOREIGN KEY constraint failed`.
///
/// Those two rows used to arrive only with the first successful pull, which
/// made the whole app wait for the network before it could create anything —
/// the one thing this design exists not to do. Worse, it failed silently: a
/// write that throws leaves the screen looking exactly as if nothing had been
/// typed.
///
/// So they are written locally the moment we know the two identifiers, which
/// is at sign-in, from the response we already have in hand.
public enum LocalIdentity {
    /// Placeholders are stamped at the epoch.
    ///
    /// Last-write-wins compares `updated_at`, so a row stamped at the epoch
    /// loses to the server's copy the instant it arrives — which is the point:
    /// these rows stand in for the real ones, they do not compete with them.
    /// They are also written clean, never dirty, so a made-up household name
    /// can never be pushed over the real one.
    static let placeholderStamp = Date(timeIntervalSince1970: 0)

    /// Writes the household and the current person, if they are not there yet.
    ///
    /// Idempotent: `INSERT OR IGNORE`, so a row that already exists — whether
    /// placed here or pulled from the server — is left exactly as it is.
    ///
    /// The names are what the person just typed, when this is called from
    /// sign-in. At launch there is nothing to pass and the placeholders stand
    /// until the first pull replaces them.
    @discardableResult
    public static func ensure(
        in database: AppDatabase,
        householdID: UUID,
        userID: UUID,
        householdName: String? = nil,
        displayName: String? = nil,
        inviteCode: String? = nil
    ) throws -> Bool {
        let stamp = Timestamp.string(from: placeholderStamp)

        let wrote = try database.writer.write { db -> Bool in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO households
                        (id, name, invite_code, created_at, updated_at, updated_by,
                         deleted_at, dirty)
                    VALUES (?, ?, ?, ?, ?, NULL, NULL, 0)
                    """,
                arguments: [
                    householdID.uuidString,
                    householdName ?? "Календарь",
                    inviteCode ?? "",
                    stamp,
                    stamp,
                ]
            )
            let household = db.changesCount

            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO users
                        (id, household_id, display_name, color, created_at, updated_at,
                         updated_by, deleted_at, dirty)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, 0)
                    """,
                arguments: [
                    userID.uuidString,
                    householdID.uuidString,
                    displayName ?? "Я",
                    "#3478F6",
                    stamp,
                    stamp,
                ]
            )
            return household > 0 || db.changesCount > 0
        }

        if wrote {
            Log.database.info("wrote the local household and user rows")
        }
        return wrote
    }
}
