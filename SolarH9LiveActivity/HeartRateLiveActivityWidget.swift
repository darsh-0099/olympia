import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SolarH9LiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HeartRateLiveActivityWidget()
        OlympiaLaunchWidget()
    }
}

struct OlympiaLaunchWidget: Widget {
    let kind = "OlympiaLaunchWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OlympiaLaunchProvider()) { entry in
            ZStack {
                Color(red: 0.06, green: 0.08, blue: 0.10)
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.title2).foregroundStyle(Color(red: 0.39, green: 0.78, blue: 1))
                    Text("OLYMPIA").font(.caption2.bold()).tracking(2)
                    Text("Time to work").font(.headline)
                    Text("Open your workout →").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { Color(red: 0.06, green: 0.08, blue: 0.10) }
            .widgetURL(URL(string: "olympia://home"))
        }
        .configurationDisplayName("Olympia")
        .description("Open your training plan and start a workout.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct OlympiaLaunchEntry: TimelineEntry { let date: Date }
private struct OlympiaLaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> OlympiaLaunchEntry { OlympiaLaunchEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (OlympiaLaunchEntry) -> Void) {
        completion(OlympiaLaunchEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OlympiaLaunchEntry>) -> Void) {
        completion(Timeline(entries: [OlympiaLaunchEntry(date: .now)], policy: .never))
    }
}

private let previewAttributes = HeartRateActivityAttributes(
    activityID: UUID(), startedAt: Date().addingTimeInterval(-425), mode: .monitoring, isSimulated: false
)
private let previewGoodState = HeartRateActivityAttributes.ContentState(
    beatsPerMinute: 132, averageBeatsPerMinute: nil, phase: .recording, updatedAt: .now,
    pulse: true, zone: 2, targetZone: nil, connectionQuality: .good
)
private let previewPoorState = HeartRateActivityAttributes.ContentState(
    beatsPerMinute: 132, averageBeatsPerMinute: nil, phase: .reconnecting, updatedAt: .now,
    pulse: false, zone: 2, targetZone: nil, connectionQuality: .poor
)
private let previewDisconnectedState = HeartRateActivityAttributes.ContentState(
    beatsPerMinute: nil, averageBeatsPerMinute: nil, phase: .reconnecting, updatedAt: .now,
    pulse: false, zone: nil, targetZone: nil, connectionQuality: .disconnected
)

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    HeartRateLiveActivityWidget()
} contentStates: {
    previewGoodState
    previewPoorState
    previewDisconnectedState
}

#Preview("Dynamic Island Compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    HeartRateLiveActivityWidget()
} contentStates: {
    previewGoodState
}

#Preview("Dynamic Island Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    HeartRateLiveActivityWidget()
} contentStates: {
    previewGoodState
    previewPoorState
}

struct HeartRateLiveActivityWidget: Widget {
    private let solarOrange = Color(red: 0.39, green: 0.78, blue: 1.0)
    private let solarCyan = Color(red: 0.275, green: 0.82, blue: 0.88)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HeartRateActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color(red: 0.055, green: 0.059, blue: 0.071))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        pulseHeart(context.state)
                        Text(context.attributes.mode.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    bpmView(context.state, size: 34)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        compactZoneStrip(context.state)
                        HStack {
                            Label(context.state.connectionQuality.label, systemImage: connectionSymbol(context.state.connectionQuality))
                                .font(.caption)
                                .foregroundStyle(context.state.connectionQuality == .good ? solarCyan : .secondary)
                            Spacer()
                            if let average = context.state.averageBeatsPerMinute {
                                Text("AVG \(average)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let target = targetDescription(context.state) {
                            Text(target).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                pulseHeart(context.state)
            } compactTrailing: {
                HStack(spacing: 3) {
                    Text(context.state.beatsPerMinute.map(String.init) ?? "–")
                        .contentTransition(.numericText())
                    Text("bpm")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit().weight(.bold))
            } minimal: {
                pulseHeart(context.state)
            }
            .keylineTint(solarOrange)
        }
    }

    private func lockScreenView(_ context: ActivityViewContext<HeartRateActivityAttributes>) -> some View {
        VStack(spacing: 9) {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(solarOrange.opacity(0.14))
                    .frame(width: 48, height: 48)
                pulseHeart(context.state)
                    .font(.title2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(context.attributes.mode.title)
                        .font(.headline)
                    if context.attributes.isSimulated {
                        Text("DEMO")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(solarOrange.opacity(0.18), in: Capsule())
                    }
                }
                Label(phaseLabel(context.state.phase), systemImage: phaseSymbol(context.state.phase))
                    .font(.caption)
                    .foregroundStyle(context.state.phase == .recording ? solarCyan : .secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                bpmView(context.state, size: 38)
                Text([context.state.zone.map { "Zone \($0)" }, context.state.connectionQuality.label]
                    .compactMap { $0 }.joined(separator: " • "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let target = targetDescription(context.state) {
                    Text(target).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        compactZoneStrip(context.state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func compactZoneStrip(_ state: HeartRateActivityAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { zone in
                Capsule()
                    .fill(zoneColor(zone).opacity(state.zone == zone ? 1 : 0.22))
                    .frame(height: state.zone == zone ? 9 : 6)
                    .overlay { Capsule().stroke(state.targetZone == zone ? Color.white : .clear, lineWidth: 1.5) }
                    .shadow(color: state.zone == zone ? zoneColor(zone).opacity(0.8) : .clear, radius: 5)
            }
        }
        .accessibilityLabel(zoneAccessibility(state))
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: Color(red: 0.30, green: 0.72, blue: 0.95)
        case 2: Color(red: 0.28, green: 0.84, blue: 0.67)
        case 3: Color(red: 0.95, green: 0.82, blue: 0.31)
        case 4: solarOrange
        default: Color(red: 0.95, green: 0.28, blue: 0.48)
        }
    }

    private func connectionSymbol(_ quality: HeartRateActivityAttributes.ContentState.ConnectionQuality) -> String {
        switch quality { case .good: "antenna.radiowaves.left.and.right"; case .poor: "exclamationmark.triangle"; case .disconnected: "xmark.circle" }
    }

    private func pulseHeart(_ state: HeartRateActivityAttributes.ContentState) -> some View {
        ActivityPulseHeart(active: state.phase == .recording, pulse: state.pulse,
                           activeColor: solarOrange, appReduceMotion: state.reduceMotion)
    }

    private func targetDescription(_ state: HeartRateActivityAttributes.ContentState) -> String? {
        guard let target = state.targetZone else { return nil }
        guard let current = state.zone else { return "Target Z\(target) • relationship unavailable" }
        let relationship = current < target ? "below target" : current > target ? "above target" : "in target"
        return "Target Z\(target) • \(relationship)"
    }

    private func zoneAccessibility(_ state: HeartRateActivityAttributes.ContentState) -> String {
        var parts = [state.zone.map { "Heart-rate zone \($0)" } ?? "Heart-rate zone unavailable"]
        if let target = targetDescription(state) { parts.append(target) }
        parts.append(state.connectionQuality.label)
        return parts.joined(separator: ", ")
    }

    private func bpmView(_ state: HeartRateActivityAttributes.ContentState, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(state.beatsPerMinute.map(String.init) ?? "–")
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("bpm")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.beatsPerMinute.map { "Heart rate, \($0) beats per minute" } ?? "Heart rate unavailable")
    }

    private func phaseLabel(_ phase: HeartRateActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .recording: "Live"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting"
        case .saving: "Saving"
        }
    }

    private func phaseSymbol(_ phase: HeartRateActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .recording: "dot.radiowaves.left.and.right"
        case .paused: "pause.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .saving: "checkmark.circle"
        }
    }
}

private struct ActivityPulseHeart: View {
    let active: Bool
    let pulse: Bool
    let activeColor: Color
    let appReduceMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || appReduceMotion {
            image
        } else {
            image.symbolEffect(.pulse, value: pulse)
        }
    }

    private var image: some View {
        Image(systemName: active ? "heart.fill" : "heart")
            .foregroundStyle(active ? activeColor : .secondary)
            .accessibilityHidden(true)
    }
}
