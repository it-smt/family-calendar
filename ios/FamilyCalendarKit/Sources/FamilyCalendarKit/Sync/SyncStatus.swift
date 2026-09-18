import Foundation
import Observation

/// What the UI is allowed to know about syncing.
///
/// One flag. Network errors are handled in the background and never surface as
/// an alert: the user sees "not synchronised" and carries on, because the data
/// in front of them is the source of truth either way.
@MainActor
@Observable
public final class SyncStatus {
    public private(set) var pendingChanges: Int = 0
    public private(set) var lastSyncedAt: Date?
    public private(set) var isSyncing: Bool = false

    /// True when there is local work the server has not acknowledged. The only
    /// thing worth showing.
    public var hasUnsyncedChanges: Bool { pendingChanges > 0 }

    public init() {}

    func update(pending: Int, lastSyncedAt: Date?, isSyncing: Bool) {
        self.pendingChanges = pending
        self.lastSyncedAt = lastSyncedAt
        self.isSyncing = isSyncing
    }
}
