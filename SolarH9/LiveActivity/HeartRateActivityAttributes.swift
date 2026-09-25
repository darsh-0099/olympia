import ActivityKit
import Foundation

struct HeartRateActivityAttributes: ActivityAttributes, Sendable {
    enum Mode: String, Codable, Hashable, Sendable {
        case monitoring
        case workout

        var title: String { self == .monitoring ? "Monitoring" : "Workout" }
    }

    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case recording
            case paused
            case reconnecting
            case saving
        }

        enum ConnectionQuality: String, Codable, Hashable, Sendable {
            case good
            case poor
            case disconnected

            var label: String {
                switch self {
                case .good: "Good signal"
                case .poor: "Signal delayed"
                case .disconnected: "Disconnected"
                }
            }
        }

        let beatsPerMinute: Int?
        let averageBeatsPerMinute: Int?
        let phase: Phase
        let updatedAt: Date
        let pulse: Bool
        let zone: Int?
        let targetZone: Int?
        let connectionQuality: ConnectionQuality
        var reduceMotion: Bool = false

        init(beatsPerMinute: Int?, averageBeatsPerMinute: Int?, phase: Phase, updatedAt: Date,
             pulse: Bool, zone: Int?, targetZone: Int?, connectionQuality: ConnectionQuality,
             reduceMotion: Bool = false) {
            self.beatsPerMinute = beatsPerMinute; self.averageBeatsPerMinute = averageBeatsPerMinute
            self.phase = phase; self.updatedAt = updatedAt; self.pulse = pulse
            self.zone = zone; self.targetZone = targetZone; self.connectionQuality = connectionQuality
            self.reduceMotion = reduceMotion
        }

        private enum CodingKeys: String, CodingKey {
            case beatsPerMinute, averageBeatsPerMinute, phase, updatedAt, pulse
            case zone, targetZone, connectionQuality, reduceMotion
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            beatsPerMinute = try values.decodeIfPresent(Int.self, forKey: .beatsPerMinute)
            averageBeatsPerMinute = try values.decodeIfPresent(Int.self, forKey: .averageBeatsPerMinute)
            phase = try values.decode(Phase.self, forKey: .phase)
            updatedAt = try values.decode(Date.self, forKey: .updatedAt)
            pulse = try values.decode(Bool.self, forKey: .pulse)
            zone = try values.decodeIfPresent(Int.self, forKey: .zone)
            targetZone = try values.decodeIfPresent(Int.self, forKey: .targetZone)
            connectionQuality = try values.decodeIfPresent(ConnectionQuality.self, forKey: .connectionQuality) ??
                (beatsPerMinute == nil ? .disconnected : .poor)
            reduceMotion = try values.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        }
    }

    let activityID: UUID
    let startedAt: Date
    let mode: Mode
    let isSimulated: Bool

    init(activityID: UUID, startedAt: Date, mode: Mode, isSimulated: Bool) {
        self.activityID = activityID; self.startedAt = startedAt; self.mode = mode; self.isSimulated = isSimulated
    }

    private enum CodingKeys: String, CodingKey { case activityID, sessionID, startedAt, mode, purpose, isSimulated }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activityID = try values.decodeIfPresent(UUID.self, forKey: .activityID) ?? values.decode(UUID.self, forKey: .sessionID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .workout
        isSimulated = try values.decode(Bool.self, forKey: .isSimulated)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(activityID, forKey: .activityID)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(mode, forKey: .mode)
        try values.encode(isSimulated, forKey: .isSimulated)
    }
}
