import Foundation
import Testing

@testable import FamilyCalendarKit

/// Список недавних входов.
///
/// Удобство, а не данные — но у удобства есть правило, и правило стоит
/// проверить: одна строка на человека и сервер, свежие сверху, и повторный
/// вход не должен обеднять запись. Имя спрашивают только при регистрации, так
/// что вход без имени поверх записи с именем — обычный случай, а не
/// исключение.
struct RecentSignInsTests {
    private func entry(
        _ email: String,
        server: String = "https://api.example.com",
        name: String? = nil,
        household: String? = nil,
        code: String? = nil,
        at seconds: TimeInterval = 0
    ) -> RecentSignIn {
        RecentSignIn(
            displayName: name,
            email: email,
            server: server,
            householdName: household,
            inviteCode: code,
            lastUsed: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func theNewestEntryComesFirst() {
        let list = RecentSignIns.merging(entry("b@example.com"), into: [entry("a@example.com")])
        #expect(list.map(\.email) == ["b@example.com", "a@example.com"])
    }

    @Test func theSamePersonOnTheSameServerIsOneRow() {
        let first = entry("a@example.com", name: "Саша")
        let list = RecentSignIns.merging(entry("a@example.com"), into: [first, entry("b@example.com")])
        #expect(list.count == 2)
        #expect(list.first?.email == "a@example.com")
    }

    /// Вход не спрашивает имя. Если бы запись перезаписывалась целиком, после
    /// первого же возвращения в списке остался бы голый адрес почты.
    @Test func whatTheNewEntryDoesNotKnowSurvivesFromTheOldOne() {
        let known = entry("a@example.com", name: "Саша", household: "Наш", code: "ABCDEFGH")
        let list = RecentSignIns.merging(entry("a@example.com"), into: [known])
        #expect(list.first?.displayName == "Саша")
        #expect(list.first?.householdName == "Наш")
        #expect(list.first?.inviteCode == "ABCDEFGH")
    }

    @Test func whatTheNewEntryDoesKnowWins() {
        let known = entry("a@example.com", name: "Саша")
        let list = RecentSignIns.merging(entry("a@example.com", name: "Александр"), into: [known])
        #expect(list.first?.displayName == "Александр")
    }

    /// Одна почта на двух серверах — два разных календаря, не имеющих друг к
    /// другу отношения.
    @Test func theSameEmailOnAnotherServerIsAnotherRow() {
        let elsewhere = entry("a@example.com", server: "https://api.other.com")
        let list = RecentSignIns.merging(entry("a@example.com"), into: [elsewhere])
        #expect(list.count == 2)
    }

    @Test func theListDoesNotGrowPastItsLimit() {
        var list: [RecentSignIn] = []
        for index in 0..<(RecentSignIns.limit + 3) {
            list = RecentSignIns.merging(entry("person\(index)@example.com"), into: list)
        }
        #expect(list.count == RecentSignIns.limit)
        // Обрезают хвост, а не голову: только что вошедший остаётся.
        #expect(list.first?.email == "person\(RecentSignIns.limit + 2)@example.com")
    }
}
