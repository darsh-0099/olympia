import Charts
import SwiftUI

struct TrendsView: View {
    private enum MetricSelection: String, CaseIterable, Identifiable {
        case restingHeartRate = "Resting HR"
        case hrv = "RMSSD"
        case trainingLoad = "Load"
        case zoneTwo = "Zone 2"
        var id: Self { self }
    }
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.solarTheme) private var theme
    @State private var range = 7
    @State private var metricSelection: MetricSelection = .restingHeartRate

    private var visible: [SessionOverview] {
        let cutoff = Date().addingTimeInterval(Double(-range) * 86_400)
        return Array(productStore.realSessions.filter {
            $0.session.startedAtUTC >= cutoff &&
            ([.trainingLoad, .zoneTwo].contains(metricSelection) ? $0.session.purpose == .exerciseSession : $0.session.purpose == .restingCheckIn)
        }.reversed())
    }

    private func value(_ item: SessionOverview) -> Double? {
        switch metricSelection {
        case .restingHeartRate: item.averageHeartRate.value
        case .hrv: item.rmssd.value
        case .trainingLoad: item.trainingLoad.value
        case .zoneTwo: (item.secondsByZone[2] ?? 0) / 60
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SolarBackground()
                VStack(spacing: SolarSpace.lg) {
                    Picker("Trend range", selection: $range) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("trends.range")
                    Picker("Metric", selection: $metricSelection) {
                        ForEach(MetricSelection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("trends.metric")

                    if visible.isEmpty {
                        ContentUnavailableView("No real trend data yet", systemImage: "chart.xyaxis.line",
                                               description: Text("Complete real H9 sessions. Demo sessions never appear here."))
                    } else {
                        Chart(visible) { item in
                            if let value = value(item) {
                                LineMark(x: .value("Date", item.session.startedAtUTC), y: .value("Value", value))
                                    .foregroundStyle(theme.accent)
                                PointMark(x: .value("Date", item.session.startedAtUTC), y: .value("Value", value))
                                    .foregroundStyle(theme.secondaryAccent)
                            }
                        }
                        .frame(minHeight: 260)
                        .accessibilityLabel("\(metricSelection.rawValue) trend")
                        .accessibilityValue("\(visible.compactMap(value).count) available real-session values in the last \(range) days")

                        List(visible) { item in
                            NavigationLink {
                                SessionSummaryView(overview: item)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.session.purpose == .restingCheckIn ? "Resting check-in" : "Workout").font(.headline)
                                    Text(item.session.startedAtUTC.formatted(date: .abbreviated, time: .shortened))
                                    Text(value(item).map { "\(metricSelection.rawValue): \($0.formatted(.number.precision(.fractionLength(0...1))))" }
                                         ?? "\(metricSelection.rawValue) unavailable")
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .padding(SolarSpace.lg)
            }
            .navigationTitle("Trends")
            .task { await productStore.refresh() }
        }
    }
}

#Preview("Empty trends") {
    TrendsView().environmentObject(ProductStore(repository: nil))
}
