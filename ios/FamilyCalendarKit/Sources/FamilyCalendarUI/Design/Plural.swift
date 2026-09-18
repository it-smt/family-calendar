import Foundation

/// Russian counting.
///
/// "1 дело", "3 дела", "5 дел" — three forms, chosen by the last digit with the
/// teens carved out. Getting this wrong is the first thing a native reader
/// notices, and it is cheap to get right.
public func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let last = abs(count) % 10
    let lastTwo = abs(count) % 100

    if lastTwo >= 11 && lastTwo <= 14 { return "\(count) \(many)" }
    if last == 1 { return "\(count) \(one)" }
    if last >= 2 && last <= 4 { return "\(count) \(few)" }
    return "\(count) \(many)"
}
