import Foundation

enum CoachingObjective: String, CaseIterable, Identifiable, Sendable {
    case aerobicBase = "Improve aerobic base"
    case heartRateRecovery = "Improve heart-rate recovery"
    case zoneTwoTime = "Increase Zone 2 time"
    case heartRateDrift = "Reduce heart-rate drift"
    case thresholdCapacity = "Improve threshold capacity"
    case intervalTolerance = "Build interval tolerance"
    case consistency = "Improve consistency"
    var id: String { rawValue }
}

struct CoachRecommendation: Identifiable, Equatable, Sendable {
    let objective: CoachingObjective
    let headline: String
    let detail: String
    let evidence: String
    let isAvailable: Bool
    var id: String { objective.id }
}

enum CoachEngine {
    static let algorithmVersion = "coach-h9-history-v1"

    /// Uses completed, real Polar H9 workouts only. Zone totals come from the
    /// documented maximum-HR five-zone calculation. No pace, distance, medical
    /// interpretation, or proprietary readiness score is inferred.
    static func recommendations(from sessions: [SessionOverview], now: Date = Date()) -> [CoachRecommendation] {
        let workouts = sessions.filter {
            $0.session.origin == .polarH9 && $0.session.purpose == .exerciseSession &&
            $0.session.state == .completed
        }
        let recent = workouts.filter { $0.session.startedAtUTC >= now.addingTimeInterval(-28 * 86_400) }
        let zone2Minutes = recent.reduce(0) { $0 + ($1.secondsByZone[2] ?? 0) / 60 }
        let highMinutes = recent.reduce(0) { $0 + (($1.secondsByZone[4] ?? 0) + ($1.secondsByZone[5] ?? 0)) / 60 }
        let weeks = Set(recent.map { Calendar(identifier: .iso8601).component(.weekOfYear, from: $0.session.startedAtUTC) }).count

        return CoachingObjective.allCases.map { objective in
            switch objective {
            case .aerobicBase:
                return evidence(objective, workouts: recent, value: zone2Minutes,
                                headline: zone2Minutes >= 90 ? "Maintain your aerobic rhythm" : "Build gradually in Zone 2",
                                detail: "Use your recent Zone 2 total as a baseline; increase duration conservatively rather than chasing a hidden score.",
                                unit: "Zone 2 minutes in the last 28 days")
            case .zoneTwoTime:
                return evidence(objective, workouts: recent, value: zone2Minutes,
                                headline: "Make Zone 2 time visible",
                                detail: "Aim to make the next four-week total slightly more consistent than the current observed total.",
                                unit: "observed Zone 2 minutes over 28 days")
            case .thresholdCapacity:
                return unavailable(objective, "Zone 4–5 totals do not prove a threshold protocol. A documented sustained-work bout detector is required before coaching this objective.")
            case .intervalTolerance:
                return unavailable(objective, "Aggregate upper-zone time does not identify work/recovery intervals. A documented interval detector is required before coaching this objective.")
            case .consistency:
                guard !recent.isEmpty else { return unavailable(objective, "Complete a real H9 workout to establish a history.") }
                return .init(objective: objective, headline: "Train across repeatable weeks",
                             detail: "Consistency is counted from weeks containing at least one completed real workout.",
                             evidence: "\(recent.count) workouts across \(weeks) of the last 4 weeks • \(algorithmVersion)", isAvailable: true)
            case .heartRateRecovery:
                let recoveries = recent.compactMap(\.recovery.value)
                guard !recoveries.isEmpty else { return unavailable(objective, "A continuous one-minute post-exercise recovery protocol has not been recorded.") }
                let average = recoveries.reduce(0, +) / Double(recoveries.count)
                return .init(objective: objective, headline: "Track like-for-like recovery",
                             detail: "Compare the one-minute BPM drop only under the same documented cooldown protocol.",
                             evidence: "Mean observed 1-minute drop: \(Int(average.rounded())) bpm • \(algorithmVersion)", isAvailable: true)
            case .heartRateDrift:
                return unavailable(objective, "Heart-rate-only data cannot distinguish drift from changing workload. Add a documented steady-workload source before coaching this objective.")
            }
        }
    }

    private static func evidence(_ objective: CoachingObjective, workouts: [SessionOverview], value: Double,
                                 headline: String, detail: String, unit: String) -> CoachRecommendation {
        guard !workouts.isEmpty, workouts.contains(where: { !$0.secondsByZone.isEmpty }) else {
            return unavailable(objective, "Complete a real H9 workout and configure maximum heart rate to calculate zones.")
        }
        return .init(objective: objective, headline: headline, detail: detail,
                     evidence: "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit) • \(algorithmVersion)",
                     isAvailable: true)
    }

    private static func unavailable(_ objective: CoachingObjective, _ reason: String) -> CoachRecommendation {
        .init(objective: objective, headline: "More comparable data needed", detail: reason,
              evidence: "Unavailable • \(algorithmVersion)", isAvailable: false)
    }
}
