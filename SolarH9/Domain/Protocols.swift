import Foundation
import Dispatch

protocol SolarClock: Sendable {
    func nowUTC() -> Date
    func monotonicNanoseconds() -> UInt64
}

struct SystemSolarClock: SolarClock {
    func nowUTC() -> Date { Date() }

    func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum HeartRateDataEvent: Sendable, Equatable {
    case heartRate(HeartRateSampleValue)
    case rrIntervals([RRIntervalValue])
    case interruptionStarted(id: UUID, at: Date, reason: String)
    case interruptionEnded(id: UUID, at: Date)
    case dataLoss(at: Date, reason: String)
}

protocol HeartRateDataSource: AnyObject, Sendable {
    /// Returns the source-lifetime, single-consumer event stream. Implementations
    /// create it once and keep it alive across start/stop cycles; stop suspends
    /// emission but does not finish the stream. Permanent source teardown finishes it.
    func eventStream() async -> AsyncStream<HeartRateDataEvent>
    func start() async throws
    func stop() async
}

enum SessionQueryScope: Sendable {
    case realOnly
    case simulatedOnly
    case all
}

@MainActor protocol SessionRepository: Sendable {
    func save(_ draft: SessionDraft) async throws
    func session(id: UUID) async throws -> SessionDraft?
    func sessions(scope: SessionQueryScope) async throws -> [SessionDraft]
    func deleteSession(id: UUID) async throws
}

@MainActor protocol RealSessionReading: Sendable {
    func baselineEligibleSessions() async throws -> [SessionDraft]
}

extension SessionRepository {
    func sessions() async throws -> [SessionDraft] {
        try await sessions(scope: .realOnly)
    }
}
