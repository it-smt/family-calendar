import FamilyCalendarKit
import SwiftUI

/// «Слава перенёс врача на 16:00».
///
/// Фраза собирается в модели, а не хранится: сервер держит глагол и ярлык; кто
/// из двоих «ты» и на каком это языке — знает только телефон. Экран здесь
/// только рисует.
public struct ActivityFeedView: View {
    @State private var model: ActivityFeedViewModel

    public init(environment: AppEnvironment) {
        _model = State(wrappedValue: ActivityFeedViewModel(environment: environment))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Theme.ScreenHeader(
                    "Изменения",
                    subtitle: model.isEmpty ? nil : "Кто что трогал",
                    gradient: Theme.feedGradient
                )

                if model.isEmpty {
                    empty
                } else {
                    days
                }
            }
        }
        .headeredScreen()
        .task { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    // MARK: Лента

    private var days: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(model.days) { day in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(day.title)
                    ForEach(day.lines) { line in
                        row(line)
                    }
                }
            }

            if model.mayHaveMore {
                Button("Показать ещё") {
                    withAnimation(.snappy) { model.showMore() }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }

    private func row(_ line: ActivityFeedViewModel.Line) -> some View {
        let colour = Color(hex: line.colorHex)
        return HStack(alignment: .top, spacing: 12) {
            // Инициал вместо аватара: фотографий у нас нет, а две буквы на
            // цветном кружке различаются с той же одной секунды.
            Text(line.initial)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(colour))

            VStack(alignment: .leading, spacing: 3) {
                Text(line.sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: line.icon)
                        .font(.caption2)
                    Text(line.at, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .card(tint: colour)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Пока ничего")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Здесь появится всё, что меняет каждый из вас")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .card()
        .padding(.horizontal, 16)
        .padding(.top, 28)
    }
}
