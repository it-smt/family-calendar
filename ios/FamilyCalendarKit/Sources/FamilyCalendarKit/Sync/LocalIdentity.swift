import Foundation
import GRDB
import OSLog

/// The two rows every other row points at.
///
/// Every table in the schema carries `household_id NOT NULL REFERENCES
/// households (id)`, and foreign keys are on. With the `households` and `users`
/// tables empty, a device cannot insert anything at all: the first task, the
/// first category, the first item on the shopping list all fail at COMMIT with
/// `FOREIGN KEY constraint failed`.
///
/// Those two rows used to arrive only with the first successful pull, which
/// made the whole app wait for the network before it could create anything —
/// the one thing this design exists not to do. So they are written locally the
/// moment the two identifiers are known, which is at sign-in, from the response
/// already in hand.
public enum LocalIdentity {
    /// Placeholders are stamped at the epoch.
    ///
    /// Last-write-wins compares `updated_at`, so a row stamped at the epoch
    /// loses to the server's copy the instant it arrives — which is the point:
    /// these rows stand in for the real ones, they do not compete with them.
    /// They are also written clean, never dirty, so a made-up household name
    /// can never be pushed over the real one.
    static let placeholderStamp = Date(timeIntervalSince1970: 0)

    public enum Failure: Error, CustomStringConvertible {
        case notWritten(household: String, user: String)

        public var description: String {
            switch self {
            case .notWritten(let household, let user):
                "the local household (\(household)) or user (\(user)) row is missing "
                    + "and could not be written; nothing can be added until it is"
            }
        }
    }

    /// A stand-in for the invite code, until the real one arrives.
    ///
    /// The household's own identifier, because `invite_code` carries a unique
    /// index and two households sharing a placeholder would collide. A real
    /// code is eight characters, so this is never mistaken for one — and
    /// `isPlaceholder` is what the interface asks rather than guessing.
    static func placeholderInviteCode(for householdID: UUID) -> String {
        householdID.uuidString
    }

    public static func isPlaceholder(inviteCode: String, of householdID: UUID) -> Bool {
        inviteCode.isEmpty || inviteCode == placeholderInviteCode(for: householdID)
    }

    /// Writes the household and the current person, if they are not there yet.
    ///
    /// Idempotent, and noisy on purpose: it says what it found and what it did
    /// every time, at a level that is never filtered out. An earlier version
    /// used `INSERT OR IGNORE` and said nothing when it inserted nothing, which
    /// is indistinguishable from not having run — and when a row was dropped
    /// for a reason nobody expected, the app went back to refusing every write
    /// with no clue as to why.
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
        let household = householdID.uuidString
        let user = userID.uuidString

        let wrote = try database.writer.write { db -> Bool in
            // A different household in this database means somebody else has
            // signed in on this phone. Their rows are not ours to show, to
            // push, or to keep: everything goes, and the cursor with it, so
            // the first pull fills an empty house rather than two.
            if try holdsAnotherHousehold(db, than: household) {
                Log.database.notice("another household was here; clearing it out")
                try clearEverything(db)
            }

            let hasHousehold = try exists(db, table: "households", id: household)
            let hasUser = try exists(db, table: "users", id: user)

            if hasHousehold && hasUser {
                Log.database.notice(
                    "local identity already in place: household \(household, privacy: .public), user \(user, privacy: .public)"
                )
                return false
            }

            // Plain inserts. Anything that goes wrong here throws and says so,
            // rather than being quietly dropped and leaving the app unable to
            // write a single row.
            if !hasHousehold {
                try db.execute(
                    sql: """
                        INSERT INTO households
                            (id, name, invite_code, created_at, updated_at, updated_by,
                             deleted_at, dirty)
                        VALUES (?, ?, ?, ?, ?, NULL, NULL, 0)
                        """,
                    arguments: [
                        household,
                        householdName ?? "Календарь",
                        inviteCode ?? placeholderInviteCode(for: householdID),
                        stamp,
                        stamp,
                    ]
                )
            }

            if !hasUser {
                try db.execute(
                    sql: """
                        INSERT INTO users
                            (id, household_id, display_name, color, created_at, updated_at,
                             updated_by, deleted_at, dirty)
                        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, 0)
                        """,
                    arguments: [user, household, displayName ?? "Я", "#3478F6", stamp, stamp]
                )
            }

            Log.database.notice(
                "wrote the local identity: household \(household, privacy: .public) (new: \(!hasHousehold, privacy: .public)), user \(user, privacy: .public) (new: \(!hasUser, privacy: .public))"
            )
            return true
        }

        // Read it back. The whole point of these rows is that every later write
        // depends on them, so "probably there" is not good enough — and a
        // failure here is worth a plain error rather than a thousand foreign
        // key violations further down.
        let present = try database.reader.read { db in
            try exists(db, table: "households", id: household)
                && exists(db, table: "users", id: user)
        }
        guard present else {
            Log.database.error(
                "local identity still missing after writing it: household \(household, privacy: .public), user \(user, privacy: .public)"
            )
            throw Failure.notWritten(household: household, user: user)
        }

        return wrote
    }

    private static func holdsAnotherHousehold(_ db: Database, than household: String) throws
        -> Bool
    {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM households WHERE id <> ?)",
            arguments: [household]
        ) ?? false
    }

    /// Every synchronised table, and the cursor.
    ///
    /// A hard delete rather than tombstones: these rows belong to a household
    /// this device is leaving, and a tombstone would be an edit to somebody
    /// else's data. Nothing here is ours to push.
    private static func clearEverything(_ db: Database) throws {
        // Children first: the foreign keys are deferred, but the order costs
        // nothing and says what points at what.
        let tables = [
            "occurrence_completions", "subtasks", "reminders", "activity_entries",
            "shopping_items", "tasks", "packing_templates", "categories",
            "superseded_edits", "route_cache", "users", "households",
        ]
        for table in tables {
            try db.execute(sql: "DELETE FROM \(table)")
        }
        try db.execute(
            sql: "UPDATE sync_state SET pull_cursor = 0, last_synced_at = NULL WHERE id = 1"
        )
    }

    private static func exists(_ db: Database, table: String, id: String) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id]
        ) ?? false
    }
}
