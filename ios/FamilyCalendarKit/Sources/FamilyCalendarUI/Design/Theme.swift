import SwiftUI

/// The look of the thing.
///
/// Two surfaces, kept apart on purpose. The header is a saturated block of
/// colour that carries the date and whatever is next; everything below it sits
/// on a plain background with solid cards. An earlier version floated frosted
/// cards on a pastel gradient, and the result was pale grey on pale grey — with
/// nothing to separate one thing from another, a screen stops having parts.
public enum Theme {
    // MARK: When

    /// Two stops, dark enough at both ends to carry white type.
    ///
    /// Named rather than written out at each use, because the same colour has
    /// to appear on a header, on a button and behind a sheet, and three hand-
    /// written copies of "#1E5FCC" drift apart the first time one is changed.
    public struct Gradient: Sendable, Equatable {
        public let from: Color
        public let to: Color

        public init(_ from: String, _ to: String) {
            self.from = Color(hex: from)
            self.to = Color(hex: to)
        }

        var colors: [Color] { [from, to] }
    }

    /// One per tab, so moving between them is a change of colour and not just a
    /// change of list. The day takes the hour's; the rest are fixed, because
    /// they have no time of their own to follow.
    public static let shoppingGradient = Gradient("#0B7A6B", "#3FBF7F")
    public static let feedGradient = Gradient("#4C3FA8", "#9A4BC9")
    public static let settingsGradient = Gradient("#243B6B", "#4A79B5")

    public enum Hour: Sendable, CaseIterable {
        case night, dawn, morning, afternoon, dusk

        public static func at(_ date: Date, calendar: Calendar = .current) -> Hour {
            switch calendar.component(.hour, from: date) {
            case 5..<9: .dawn
            case 9..<13: .morning
            case 13..<18: .afternoon
            case 18..<22: .dusk
            default: .night
            }
        }

        /// Both stops are strong enough to carry white type, because the header
        /// always does. A gradient that fades to something pale looks like a
        /// mistake at the bottom edge.
        public var gradient: Gradient {
            switch self {
            case .night: Gradient("#1A1A3A", "#3D2B63")
            case .dawn: Gradient("#7A3B8F", "#E8734A")
            case .morning: Gradient("#1E5FCC", "#2FA8D9")
            case .afternoon: Gradient("#0F7B8A", "#37B5A0")
            case .dusk: Gradient("#B33A5B", "#6B2E8F")
            }
        }
    }

    /// The coloured block behind the date. Diagonal, so it has a direction, and
    /// with one darker corner so it does not read as a printed swatch.
    public struct HeaderBackground: View {
        private let gradient: Gradient

        public init(_ gradient: Gradient) {
            self.gradient = gradient
        }

        /// The day's own header: whatever colour that hour of that day is.
        public init(at date: Date) {
            self.gradient = Hour.at(date).gradient
        }

        public var body: some View {
            ZStack {
                LinearGradient(
                    colors: gradient.colors, startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [.white.opacity(0.22), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: 320
                )
                .blendMode(.softLight)
            }
        }
    }

    /// The coloured block a screen starts with: a big title, room for a control
    /// or two on the right, and a curve at the bottom so the plain background
    /// below it looks like it is sliding underneath rather than butting up.
    public struct ScreenHeader<Trailing: View>: View {
        private let title: String
        private let subtitle: String?
        private let gradient: Gradient
        private let trailing: Trailing

        public init(
            _ title: String,
            subtitle: String? = nil,
            gradient: Gradient,
            @ViewBuilder trailing: () -> Trailing
        ) {
            self.title = title
            self.subtitle = subtitle
            self.gradient = gradient
            self.trailing = trailing()
        }

        public var body: some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 14) { trailing }
                    .foregroundStyle(.white)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 18)
            .padding(.top, 62)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HeaderBackground(gradient))
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 30, bottomTrailingRadius: 30, style: .continuous
                )
            )
        }
    }

    // MARK: Surfaces

    public static let corner: CGFloat = 16

    /// A card. Opaque, with a real shadow — the two things that make it a
    /// separate object rather than a slightly different patch of background.
    public struct Card: ViewModifier {
        var tint: Color?

        public func body(content: Content) -> some View {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(alignment: .leading) {
                    if let tint {
                        // A stripe on the edge, clipped to the card's corner, so
                        // the colour belongs to the card rather than sitting
                        // next to it.
                        UnevenRoundedRectangle(
                            topLeadingRadius: Theme.corner,
                            bottomLeadingRadius: Theme.corner,
                            style: .continuous
                        )
                        .fill(tint)
                        .frame(width: 5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
    }

    // MARK: Colour

    /// The colours a category can be.
    ///
    /// A fixed set rather than a free colour picker: eight that sit together
    /// keep a screen looking composed, where eight arbitrary hexes make it look
    /// like a bring-your-own-mug kitchen.
    public static let swatches: [String] = [
        "#FF6B6B", "#FF922B", "#F0B429", "#51CF66",
        "#20C997", "#4DABF7", "#5C7CFA", "#CC5DE8",
    ]

    /// The nth swatch as a colour, wrapping rather than trapping — the palette
    /// is fixed here, but the places that index into it are spread across the
    /// app and should not each have to know how many there are.
    public static func swatchColor(_ index: Int) -> Color {
        let count = swatches.count
        return Color(hex: swatches[((index % count) + count) % count])
    }

    /// A colour for something that has no colour of its own — a packing list,
    /// say. Taken from the identifier rather than from the row's position, so
    /// it survives another one being added above it, and from a byte of the
    /// UUID rather than from `hashValue`, which is salted per launch and would
    /// repaint the whole screen every time the app starts.
    public static func swatchColor(for id: UUID) -> Color {
        swatchColor(Int(id.uuid.0))
    }

    /// For a task with no category. Calm on purpose — it should not compete
    /// with the ones that were given a colour deliberately.
    public static let unlabelled = Color(hex: "#8E99AB")

    /// The five a new household starts with, so the first screen has colour in
    /// it and there is something to filter by before anyone has set anything up.
    public static let starterCategories: [(name: String, colorHex: String)] = [
        ("Дом", "#4DABF7"),
        ("Дети", "#FF922B"),
        ("Здоровье", "#51CF66"),
        ("Работа", "#5C7CFA"),
        ("Важное", "#FF6B6B"),
    ]
}

extension View {
    public func card(tint: Color? = nil) -> some View {
        modifier(Theme.Card(tint: tint))
    }

    /// The plain surface everything below the header sits on.
    public func contentBackground() -> some View {
        background(Color(.systemGroupedBackground))
    }

    /// What every screen that draws its own coloured header does with it: fill
    /// the notch, hide the system bar that would otherwise sit on top of it,
    /// and put the plain surface behind the rest.
    public func headeredScreen() -> some View {
        contentBackground()
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
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

extension Theme.ScreenHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String? = nil, gradient: Theme.Gradient) {
        self.init(title, subtitle: subtitle, gradient: gradient) { EmptyView() }
    }
}

/// A small heading between groups of cards. Cards on their own are a heap; a
/// word above them is what makes it a section.
public struct SectionLabel: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
