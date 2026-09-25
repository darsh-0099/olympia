import SwiftUI

enum SolarTargetState: String, Equatable, Sendable {
    case belowTarget = "Below target"
    case inTarget = "In target"
    case aboveTarget = "Above target"
    case noTarget = "No target"
}

struct SolarZoneSnapshot: Equatable, Sendable {
    let beatsPerMinute: Int?
    let currentZone: Int?
    let targetZone: Int?

    var targetState: SolarTargetState {
        guard let targetZone, let currentZone else { return .noTarget }
        if currentZone < targetZone { return .belowTarget }
        if currentZone > targetZone { return .aboveTarget }
        return .inTarget
    }
}

enum SolarZonePalette {
    static func color(for zone: Int) -> Color {
        switch zone {
        case 1: Color(red: 0.30, green: 0.72, blue: 0.95)
        case 2: Color(red: 0.28, green: 0.84, blue: 0.67)
        case 3: Color(red: 0.95, green: 0.82, blue: 0.31)
        case 4: Color(red: 1.00, green: 0.56, blue: 0.22)
        default: Color(red: 0.95, green: 0.28, blue: 0.48)
        }
    }
}

struct SolarZoneLadder: View {
    enum Density { case full, compact }

    let snapshot: SolarZoneSnapshot
    var density: Density = .full
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.solarTheme) private var theme
    @State private var glow = false

    var body: some View {
        VStack(alignment: .leading, spacing: density == .full ? 12 : 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HEART-RATE ZONES")
                        .font(.caption2.bold()).tracking(1.35)
                        .foregroundStyle(theme.secondaryText)
                    Text(snapshot.currentZone.map { "Zone \($0)" } ?? "Zone unavailable")
                        .font(density == .full ? .title2.bold() : .headline.bold())
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(snapshot.beatsPerMinute.map(String.init) ?? "—")
                        .font((density == .full ? Font.title.bold() : Font.title3.bold()).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("BPM").font(.caption2.bold()).foregroundStyle(theme.secondaryText)
                }
            }

            HStack(spacing: density == .full ? 7 : 4) {
                ForEach(1...5, id: \.self) { zone in
                    zoneCell(zone)
                }
            }

            if density == .full, let target = snapshot.targetZone {
                Label("Target Z\(target) • \(snapshot.targetState.rawValue)",
                      systemImage: targetSymbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SolarZonePalette.color(for: target))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .onAppear { glow = true }
    }

    private func zoneCell(_ zone: Int) -> some View {
        let active = snapshot.currentZone == zone
        let target = snapshot.targetZone == zone
        let color = SolarZonePalette.color(for: zone)
        return VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? color : color.opacity(theme.highContrast ? 0.38 : 0.20))
                    .frame(height: density == .full ? 34 : 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(target ? Color.white : color.opacity(0.35), lineWidth: target ? 2 : 1)
                    }
                    .shadow(color: active ? color.opacity(glow ? 0.85 : 0.30) : .clear,
                            radius: glow ? 10 : 3)
                    .scaleEffect(active && glow ? 1.04 : 1)
                if active {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.black.opacity(0.75))
                }
            }
            Text("Z\(zone)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(active ? color : theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .animation((systemReduceMotion || theme.reducedAnimation) ? nil :
                    .easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: glow)
    }

    private var targetSymbol: String {
        switch snapshot.targetState {
        case .belowTarget: "arrow.up"
        case .inTarget: "checkmark.circle.fill"
        case .aboveTarget: "arrow.down"
        case .noTarget: "circle.dashed"
        }
    }

    private var accessibilitySummary: String {
        var values = [snapshot.beatsPerMinute.map { "\($0) beats per minute" } ?? "Heart rate unavailable",
                      snapshot.currentZone.map { "zone \($0)" } ?? "zone unavailable"]
        if let target = snapshot.targetZone { values.append("target zone \(target), \(snapshot.targetState.rawValue)") }
        return values.joined(separator: ", ")
    }
}

#Preview("Each zone") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(1...5, id: \.self) { zone in
                SolarZoneLadder(snapshot: .init(beatsPerMinute: 92 + zone * 16,
                                                currentZone: zone, targetZone: 2))
                    .padding().background(SolarColor.surface, in: RoundedRectangle(cornerRadius: 22))
            }
        }.padding()
    }.background(SolarBackground())
}
