import ActivityKit
import FamilyCalendarKit
import SwiftUI
import WidgetKit

/// The countdown on the lock screen while it is time to go.
///
/// Worth having for exactly one window — from shortly before someone has to
/// leave until they should have arrived — which is why the app starts it late
/// and ends it promptly.
@available(iOS 16.2, *)
struct LeaveTimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LeaveTimeAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(.black.opacity(0.4))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(
                        context.attributes.destinationName ?? "On your way",
                        systemImage: "figure.walk.departure"
                    )
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.arriveBy, style: .time)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.leaveAt, style: .relative)
                        .font(.title2.monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: "figure.walk.departure")
            } compactTrailing: {
                Text(context.state.leaveAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "figure.walk.departure")
            }
        }
    }
}

@available(iOS 16.2, *)
struct LockScreenView: View {
    let context: ActivityViewContext<LeaveTimeAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.attributes.taskTitle)
                .font(.headline)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(context.state.leaveAt, style: .relative)
                        .font(.title3.monospacedDigit())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(journey)
                        .font(.caption)
                    if let place = context.attributes.destinationName {
                        Text(place)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// A guess presented as a measurement is worse than a guess admitted as one.
    private var journey: String {
        context.state.isApproximate
            ? "about \(context.state.travelMinutes) min"
            : "\(context.state.travelMinutes) min with traffic"
    }
}
