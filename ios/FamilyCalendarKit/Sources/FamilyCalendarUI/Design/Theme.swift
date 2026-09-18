import SwiftUI

/// The look of the thing.
///
/// A calendar is looked at more often than it is used, usually for two seconds
/// at a time, so the background does the work of saying *when* it is before a
/// single word is read. It shifts through the day — cold and dim at night, warm
/// at dawn, open at midday, deepening in the evening — which also means the app
/// never looks the same twice in a row, and never looks flat.
public enum Theme {
    public enum Hour: Sendable {
        case night, dawn, morning, afternoon, dusk

        public static func at(_ date: Date, calendar: Calendar = .current) -> Hour {
            switch calendar.component(.hour, from: date) {
            case 0..<5: .night
            case 5..<9: .dawn
            case 9..<14: .morning
            case 14..<18: .afternoon
            case 18..<22: .dusk
            default: .night
            }
        }

        /// Two stops, low saturation. Anything louder stops being a background
        /// and starts competing with the writing on top of it.
        var colors: [Color] {
            switch self {
            case .night: [Color(hex: "#1B1B2F"), Color(hex: "#2B2A4A")]
            case .dawn: [Color(hex: "#F6C7A5"), Color(hex: "#E8A0BF")]
            case .morning: [Color(hex: "#BFD9F2"), Color(hex: "#E6EEF7")]
            case .afternoon: [Color(hex: "#CFE3F0"), Color(hex: "#F2E6D8")]
            case .dusk: [Color(hex: "#8E7AB5"), Color(hex: "#E7A17A")]
            }
        }

        /// Where the light comes from, so the gradient has a direction rather
        /// than being a stripe.
        var start: UnitPoint {
            switch self {
            case .night: .top
            case .dawn: .bottomLeading
            case .morning: .topLeading
            case .afternoon: .topTrailing
            case .dusk: .bottomTrailing
            }
        }

        var isDark: Bool { self == .night }
    }

    /// The backdrop for every screen.
    public struct Background: View {
        private let hour: Hour

        public init(at date: Date = Date()) {
            self.hour = Hour.at(date)
        }

        public var body: some View {
            ZStack {
                LinearGradient(
                    colors: hour.colors, startPoint: hour.start, endPoint: hour.start.opposite
                )

                // A soft light off one corner. Without it a two-stop gradient
                // reads as a flat sheet on a large screen.
                RadialGradient(
                    colors: [.white.opacity(hour.isDark ? 0.10 : 0.45), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 520
                )
                .blendMode(.softLight)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Surfaces

    public static let cornerRadius: CGFloat = 18
    public static let cardPadding: CGFloat = 14

    /// A card floating over the gradient.
    ///
    /// Material rather than a solid fill, so the background keeps showing
    /// through and the screen stays one thing instead of a list of boxes.
    public struct Card: ViewModifier {
        var emphasised: Bool = false

        public func body(content: Content) -> some View {
            content
                .padding(Theme.cardPadding)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(emphasised ? .regularMaterial : .thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .stroke(.white.opacity(emphasised ? 0.35 : 0.18), lineWidth: 0.8)
                )
                .shadow(
                    color: .black.opacity(emphasised ? 0.14 : 0.07),
                    radius: emphasised ? 14 : 7,
                    y: emphasised ? 7 : 3
                )
        }
    }
}

extension View {
    public func card(emphasised: Bool = false) -> some View {
        modifier(Theme.Card(emphasised: emphasised))
    }

    /// A screen: the gradient behind, the content over it, and no list chrome.
    public func themedScreen(at date: Date = Date()) -> some View {
        background(Theme.Background(at: date))
            .scrollContentBackground(.hidden)
    }
}

extension UnitPoint {
    var opposite: UnitPoint {
        UnitPoint(x: 1 - x, y: 1 - y)
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`, the format the categories are stored in.
    public init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red, green, blue, alpha: Double
        if cleaned.count == 8 {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
