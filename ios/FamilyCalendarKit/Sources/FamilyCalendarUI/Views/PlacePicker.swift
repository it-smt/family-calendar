import MapKit
import OSLog
import SwiftUI

import FamilyCalendarKit

/// Одно место из поиска.
///
/// `MKMapItem` — ссылочный тип и не `Sendable`, поэтому через границу актора
/// едет вот это: имя, адрес и две координаты.
struct FoundPlace: Identifiable, Sendable, Equatable {
    let id = UUID()
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
}

/// Ищет места. Обычная функция, а не метод экрана: ответ MapKit не должен
/// пересекать границу главного актора, поэтому он разбирается здесь же.
func searchPlaces(matching query: String) async throws -> [FoundPlace] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query

    let response = try await MKLocalSearch(request: request).start()
    return response.mapItems.compactMap { item in
        guard let name = item.name else { return nil }
        let coordinate = item.placemark.coordinate
        return FoundPlace(
            name: name,
            address: item.placemark.title,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

/// Выбор места на карте.
///
/// Единственное место в приложении кроме входа, которое ждёт сеть — потому что
/// координаты знает только сервер карт. Отказаться можно всегда: название
/// пишется руками и без него, просто тогда «когда выходить» нечего считать.
struct PlacePicker: View {
    let query: String
    let onPick: (FoundPlace) -> Void

    @State private var text: String = ""
    @State private var results: [FoundPlace] = []
    @State private var searching = false
    @State private var searched = false
    @State private var problem: String?
    @State private var search: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(results) { place in
                    Button {
                        onPick(place)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            if let address = place.address {
                                Text(address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if results.isEmpty && searched && !searching && problem == nil {
                    Text("Ничего не нашлось")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $text, prompt: "Название или адрес")
            .onSubmit(of: .search) { run() }
            .overlay { if searching { ProgressView() } }
            .navigationTitle("Место")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task {
                text = query
                guard !query.isEmpty else { return }
                run()
            }
            .onDisappear {
                search?.cancel()
                search = nil
            }
        }
    }

    private func run() {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }

        search?.cancel()
        problem = nil
        searching = true
        search = Task {
            defer { searching = false; searched = true }
            do {
                results = try await searchPlaces(matching: wanted)
            } catch {
                // Сеть, а не ошибка человека: сказать и не мешать.
                Log.network.debug("place search failed: \(error.localizedDescription, privacy: .public)")
                results = []
                problem = "Карты не отвечают. Напиши место словами — это тоже работает."
            }
        }
    }
}

extension TravelMode {
    /// Как этот способ добраться называется в системных картах.
    var mapsMode: String {
        switch self {
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .driving, .none: MKLaunchOptionsDirectionsModeDriving
        }
    }
}
