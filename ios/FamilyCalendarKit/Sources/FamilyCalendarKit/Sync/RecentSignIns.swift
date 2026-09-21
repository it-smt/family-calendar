import Foundation
import OSLog

/// Кто уже входил с этого телефона.
///
/// Экран входа — единственное место в приложении, где надо что-то набирать
/// вслепую: почту, адрес сервера, иногда код приглашения из восьми знаков.
/// Набирают это ровно тогда, когда приложение только что переустановили или
/// подпись протухла, то есть в самый неудачный момент. Помнить, что здесь уже
/// было, стоит дёшево и экономит именно ту минуту.
///
/// Пароля здесь нет и не будет. Он лежит в Keychain, и «Выйти» его стирает —
/// в этом весь смысл выхода. Запомненная запись возвращает почту, адрес и
/// имя; пароль набирает человек или подставляет сама iOS из связки ключей.
public struct RecentSignIn: Codable, Sendable, Equatable, Identifiable {
    /// Как человека зовут — то, что он набрал при регистрации. Может не быть:
    /// при входе имя не спрашивают.
    public var displayName: String?
    public var email: String
    /// Адрес сервера строкой, как его сохранил ``ServerAddress``.
    public var server: String
    /// Название календаря, если оно известно. Знаем только у того, кто его
    /// заводил.
    public var householdName: String?
    /// Код, по которому сюда когда-то присоединились. Нужен, если телефон
    /// сменили и заходят заново с нуля.
    public var inviteCode: String?
    public var lastUsed: Date

    public init(
        displayName: String? = nil,
        email: String,
        server: String,
        householdName: String? = nil,
        inviteCode: String? = nil,
        lastUsed: Date = Date()
    ) {
        self.displayName = displayName
        self.email = email
        self.server = server
        self.householdName = householdName
        self.inviteCode = inviteCode
        self.lastUsed = lastUsed
    }

    /// Один и тот же человек на двух разных серверах — две разные записи:
    /// почта совпадает, а календари не имеют друг к другу отношения.
    public var id: String { "\(email)@\(server)" }

    /// Чем подписать строку в списке.
    public var title: String { displayName ?? email }

    /// Что дописать мелким шрифтом, не повторяя заголовок.
    public var subtitle: String {
        let host = URL(string: server)?.host() ?? server
        return displayName == nil ? host : "\(email) · \(host)"
    }
}

public enum RecentSignIns {
    static let storageKey = "FCRecentSignIns"

    /// Больше пяти — это уже не «недавние», а список, в котором ищут.
    static let limit = 5

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppDatabase.appGroupIdentifier) ?? .standard
    }

    /// Свежие сверху.
    public static var all: [RecentSignIn] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let stored = try? JSONDecoder().decode([RecentSignIn].self, from: data) else {
            // Формат мог смениться между версиями. Список — удобство, а не
            // данные: потерять его не жалко, а падать из-за него глупо.
            Log.auth.error("the remembered sign-ins could not be read; starting over")
            defaults.removeObject(forKey: storageKey)
            return []
        }
        return stored.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Записывает вход. Повторный вход тем же человеком на тот же сервер не
    /// добавляет строку, а поднимает и дополняет существующую: имя, которое
    /// когда-то набрали при регистрации, переживает вход без имени.
    public static func remember(_ entry: RecentSignIn) {
        save(merging(entry, into: all))
    }

    /// Само правило, без хранилища — чтобы его можно было проверить.
    ///
    /// Новая запись встаёт первой; прежняя с тем же ключом исчезает, отдав то,
    /// чего в новой нет; хвост обрезается по ``limit``.
    static func merging(
        _ entry: RecentSignIn, into existing: [RecentSignIn]
    ) -> [RecentSignIn] {
        var merged = entry
        var rest = existing
        if let index = rest.firstIndex(where: { $0.id == entry.id }) {
            let previous = rest.remove(at: index)
            merged.displayName = entry.displayName ?? previous.displayName
            merged.householdName = entry.householdName ?? previous.householdName
            merged.inviteCode = entry.inviteCode ?? previous.inviteCode
        }
        return [merged] + rest.prefix(limit - 1)
    }

    public static func forget(_ entry: RecentSignIn) {
        save(all.filter { $0.id != entry.id })
    }

    public static func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    private static func save(_ entries: [RecentSignIn]) {
        guard let data = try? JSONEncoder().encode(Array(entries)) else {
            Log.auth.error("the remembered sign-ins could not be written")
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
