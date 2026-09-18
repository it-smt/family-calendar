import Foundation
import Testing

@testable import FamilyCalendarKit

/// The wire format, asserted exactly.
///
/// Everything rests on this one shape. The device compares timestamps as text,
/// which is only correct while every one of them has the same fixed width — a
/// value written without milliseconds sorts *after* one with them, and
/// last-write-wins quietly inverts. The server writes the same shape from
/// Python, and a change payload is copied between the two databases without
/// conversion, so a difference here would not be a formatting bug but a sync
/// bug that loses edits.
///
/// Worth asserting to the character, because the implementation was rewritten
/// once already — `ISO8601DateFormatter` is a class and not `Sendable`, so
/// sharing one is exactly what strict concurrency refuses.
struct TimestampTests {
    /// 2026-09-18T09:00:00.000Z
    static let moment = Date(timeIntervalSince1970: 1_789_722_000)

    @Test func writesRFC3339InUTCWithMilliseconds() {
        #expect(Timestamp.string(from: Self.moment) == "2026-09-18T09:00:00.000Z")
    }

    @Test func keepsMilliseconds() {
        let withFraction = Self.moment.addingTimeInterval(0.25)

        #expect(Timestamp.string(from: withFraction) == "2026-09-18T09:00:00.250Z")
    }

    @Test func alwaysWritesTheSameWidth() {
        // A shorter or longer string would break text comparison, which is what
        // the generated SQL on the device uses to decide who wins.
        let widths = Set(
            [0.0, 0.001, 0.5, 3600, 86_400 * 365].map {
                Timestamp.string(from: Self.moment.addingTimeInterval($0)).count
            }
        )

        #expect(widths.count == 1)
        #expect(widths.first == 24)
    }

    @Test func readsWhatItWrites() throws {
        let parsed = try #require(Timestamp.date(from: Timestamp.string(from: Self.moment)))

        #expect(abs(parsed.timeIntervalSince(Self.moment)) < 0.001)
    }

    @Test func readsATimestampWithoutMilliseconds() throws {
        // Postgres omits the fractional part when it happens to be zero.
        let parsed = try #require(Timestamp.date(from: "2026-09-18T09:00:00Z"))

        #expect(abs(parsed.timeIntervalSince(Self.moment)) < 0.001)
    }

    @Test func refusesSomethingThatIsNotATimestamp() {
        #expect(Timestamp.date(from: "yesterday") == nil)
        #expect(Timestamp.date(from: "") == nil)
    }

    @Test func sortsAsTextExactlyAsItSortsInTime() {
        let offsets: [TimeInterval] = [0, 0.001, 0.5, 1, 60, 3600, 86_400, 86_400 * 400]
        let dates = offsets.map { Self.moment.addingTimeInterval($0) }

        let written = dates.map(Timestamp.string(from:))

        #expect(written == written.sorted())
    }

    @Test func aNewStampIsAlwaysAfterTheOneItReplaces() {
        // Two edits in the same millisecond must not produce the same stamp:
        // the second would lose to the first and the server would drop it.
        let previous = Self.moment
        let next = Timestamp.strictlyAfter(previous, now: previous)

        #expect(next > previous)
        #expect(Timestamp.string(from: next) != Timestamp.string(from: previous))
    }

    @Test func aLaterClockWins() {
        let previous = Self.moment
        let later = previous.addingTimeInterval(60)

        #expect(Timestamp.strictlyAfter(previous, now: later) == later)
    }

    @Test func truncationMatchesWhatTheWireCarries() {
        let noisy = Self.moment.addingTimeInterval(0.1239)

        let truncated = Timestamp.truncatedToMilliseconds(noisy)

        #expect(Timestamp.string(from: truncated) == Timestamp.string(from: noisy))
        #expect(truncated <= noisy)
    }
}
