import Charts
import SwiftUI

struct SessionSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.solarTheme) private var theme
    let overview: SessionOverview
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: overview.session.purpose == .restingCheckIn ? "Resting check-in" : "Workout")
                LabeledContent("Source", value: overview.session.origin == .polarH9 ? "Bluetooth sensor • real" : "Demo • simulated")
                LabeledContent("Duration", value: durationText)
                LabeledContent("State", value: overview.session.state.rawValue.capitalized)
            } header: { Text("Session") }

            Section("Metrics") {
                MetricPill(result: overview.averageHeartRate, systemImage: "heart.fill")
                MetricPill(result: overview.rmssd, systemImage: "waveform")
                MetricPill(result: overview.trainingLoad, systemImage: "gauge.with.dots.needle.67percent")
                if overview.session.purpose == .exerciseSession {
                    MetricPill(result: overview.recovery, systemImage: "arrow.down.heart")
                }
                Text("Measured values come from stored samples. Calculated values show quality and availability reasons instead of inventing missing data.")
                    .font(.footnote).foregroundStyle(theme.secondaryText)
            }

            Section("Recording quality") {
                LabeledContent("Heart-rate samples", value: overview.session.heartRates.count.formatted())
                LabeledContent("RR intervals", value: overview.session.rrIntervals.count.formatted())
                LabeledContent("Interruptions", value: overview.session.interruptions.count.formatted())
                LabeledContent("Paused intervals", value: overview.session.pauses.count.formatted())
                if !overview.session.interruptions.isEmpty {
                    ForEach(overview.session.interruptions) { marker in
                        Label(marker.reason, systemImage: "exclamationmark.triangle")
                    }
                }
            }

            if !overview.session.heartRates.isEmpty {
                Section("Heart-rate curve") {
                    Chart(overview.session.heartRates) { sample in
                        LineMark(x: .value("Time", sample.receivedAtUTC), y: .value("BPM", sample.beatsPerMinute))
                            .foregroundStyle(theme.accent)
                    }.frame(height: 180)
                        .accessibilityLabel("Session heart-rate curve")
                        .accessibilityValue("\(overview.session.heartRates.count) stored samples")
                }
            }
            if !overview.secondsByZone.isEmpty {
                Section("Time in zones") {
                    SolarZoneLadder(snapshot: .init(
                        beatsPerMinute: nil,
                        currentZone: dominantZone,
                        targetZone: nil
                    ))
                    Text("Dominant recorded zone by duration. Average heart rate is reported separately in Metrics.")
                        .font(.footnote).foregroundStyle(theme.secondaryText)
                    Chart(overview.secondsByZone.keys.sorted(), id: \.self) { zone in
                        BarMark(x: .value("Zone", "Z\(zone)"),
                                y: .value("Minutes", (overview.secondsByZone[zone] ?? 0) / 60))
                            .foregroundStyle(theme.secondaryAccent)
                    }.frame(height: 170)
                        .accessibilityLabel("Time in heart-rate zones")
                }
            }

            if overview.session.purpose == .exerciseSession && overview.session.origin == .polarH9 {
                Section("Coach") {
                    NavigationLink("Review coaching objectives") { CoachView(session: overview) }
                    Text("Recommendations use real H9 workout history and documented calculations only.")
                        .font(.footnote).foregroundStyle(theme.secondaryText)
                }
            }

            Section {
                Button("Prepare this session’s export files") { Task { await productStore.prepareExport(sessionID: overview.id) } }
                ForEach(productStore.exportFiles, id: \.self) { file in
                    ShareLink(item: file) { Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
                if let error = productStore.errorMessage { Text(error).foregroundStyle(theme.accent) }
                Button("Delete this session", role: .destructive) { confirmDelete = true }
            }

            Section {
                Text("SolarH9 is a wellness app, not a medical device. It is not for diagnosis or emergency monitoring.")
                    .font(.footnote).foregroundStyle(theme.secondaryText)
            }
        }
        .navigationTitle("Session summary")
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete) {
            Button("Delete session", role: .destructive) {
                Task { if await productStore.deleteSession(id: overview.id) { dismiss() } }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the session and owned samples from this iPhone.") }
    }

    private var durationText: String {
        let seconds = max(0, Int(overview.durationSeconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var dominantZone: Int? {
        overview.secondsByZone.max { $0.value < $1.value }?.key
    }
}
