import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.solarTheme) private var theme

    private var workouts: [SessionOverview] {
        productStore.realSessions.filter { $0.session.purpose == .exerciseSession }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SolarBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: SolarSpace.md) {
                        SolarCard {
                            HStack(spacing: SolarSpace.md) {
                                SolarOrbitMark(size: 58)
                                VStack(alignment: .leading, spacing: SolarSpace.xs) {
                                    Text("Your day in motion").font(.title3.bold())
                                    Text(workouts.isEmpty ? "Your real H9 workouts will appear here without requiring a journal or manual check-in." : "\(workouts.count) real workouts are available for trends and evidence-based coaching.")
                                        .font(.subheadline).foregroundStyle(theme.secondaryText)
                                }
                            }
                        }

                        SolarCard {
                            Label("Coach", systemImage: "scope").font(.headline)
                            Text("Seven objectives grounded in actual H9 workout history, with unavailable states when the evidence is not there.")
                                .font(.subheadline).foregroundStyle(theme.secondaryText)
                            NavigationLink("Open Coach") { CoachView() }
                                .buttonStyle(SolarPrimaryButtonStyle())
                                .padding(.top, SolarSpace.sm)
                        }

                        Text("Latest workout").font(.headline)
                        if let latest = workouts.first {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: SolarSpace.sm) {
                                    MetricPill(result: latest.averageHeartRate, systemImage: "heart.fill")
                                    MetricPill(result: latest.trainingLoad, systemImage: "gauge.with.dots.needle.67percent")
                                }
                                VStack(spacing: SolarSpace.sm) {
                                    MetricPill(result: latest.averageHeartRate, systemImage: "heart.fill")
                                    MetricPill(result: latest.trainingLoad, systemImage: "gauge.with.dots.needle.67percent")
                                }
                            }
                            NavigationLink("View workout summary") { SessionSummaryView(overview: latest) }
                                .accessibilityIdentifier("today.latestWorkout")
                        } else {
                            ContentUnavailableView("No real workouts yet", systemImage: "figure.run",
                                                   description: Text("Start a formal workout from Live when your H9 is connected."))
                        }
                        if let error = productStore.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(theme.accent)
                        }
                    }
                    .padding(SolarSpace.md)
                }
            }
            .navigationTitle("Today")
            .task { await productStore.refresh() }
            .refreshable { await productStore.refresh() }
        }
    }

}

private struct ReadinessDetailView: View {
    let estimate: ReadinessEstimate
    var body: some View {
        List {
            Section("Result") {
                LabeledContent("Score", value: estimate.score?.formatted() ?? "Unavailable")
                LabeledContent("Classification", value: estimate.classification.rawValue.capitalized)
                LabeledContent("Confidence", value: estimate.confidence.rawValue.capitalized)
                LabeledContent("Eligible baseline days", value: estimate.baselineDays.formatted())
                LabeledContent("Algorithm", value: estimate.algorithmVersion)
            }
            if let evidence = estimate.evidence {
                Section("Personal baseline evidence") {
                    LabeledContent("Resting HR center", value: evidence.restingHeartRateCenter.formatted(.number.precision(.fractionLength(1))))
                    LabeledContent("lnRMSSD center", value: evidence.lnRMSSDCenter.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Resting HR z-score", value: evidence.restingHeartRateZScore.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("lnRMSSD z-score", value: evidence.lnRMSSDZScore.formatted(.number.precision(.fractionLength(2))))
                }
            }
            Section("Why") { ForEach(estimate.reasons, id: \.self) { Text($0) } }
            Section { Text("This is a non-medical wellness estimate, not a diagnosis or emergency signal.") }
        }.navigationTitle("Readiness details")
    }
}

#Preview("No baseline") {
    TodayView()
        .environmentObject(ProductStore(repository: nil))
}
