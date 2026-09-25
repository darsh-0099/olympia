import SwiftUI

struct CoachView: View {
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.solarTheme) private var theme
    var session: SessionOverview?

    private var recommendations: [CoachRecommendation] {
        CoachEngine.recommendations(from: productStore.realSessions)
    }

    var body: some View {
        ZStack {
            SolarBackground()
            ScrollView {
                LazyVStack(spacing: SolarSpace.md) {
                    if let session, session.session.origin == .polarH9 {
                        SolarCard {
                            Text("FROM THIS WORKOUT").font(.caption2.bold()).foregroundStyle(theme.secondaryAccent)
                            Text(session.session.startedAtUTC.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("Average \(session.averageHeartRate.value.map { Int($0.rounded()).formatted() } ?? "—") bpm • \(Int(session.durationSeconds / 60)) min • \(Int((session.secondsByZone[2] ?? 0) / 60)) min in Zone 2")
                                .font(.subheadline).foregroundStyle(theme.secondaryText)
                            Text("The objective cards below use this workout within your real 28-day H9 history.")
                                .font(.caption).foregroundStyle(theme.secondaryText)
                        }
                    }
                    SolarCard {
                        Label("Evidence, not guesswork", systemImage: "scope")
                            .font(.title3.bold())
                        Text("Coach uses real Polar H9 workout history and documented zone calculations. It never treats the strap as a source of pace or distance.")
                            .font(.subheadline).foregroundStyle(theme.secondaryText)
                    }
                    ForEach(recommendations) { item in
                        SolarCard {
                            Text(item.objective.rawValue).font(.caption.bold()).foregroundStyle(theme.secondaryAccent)
                            Text(item.headline).font(.headline).padding(.top, 2)
                            Text(item.detail).font(.subheadline).foregroundStyle(theme.secondaryText).padding(.top, 2)
                            Text(item.evidence).font(.caption.monospacedDigit()).foregroundStyle(item.isAvailable ? theme.accent : theme.secondaryText).padding(.top, 7)
                        }
                    }
                }.padding()
            }
        }
        .navigationTitle("Coach")
    }
}
