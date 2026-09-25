import Foundation

enum DiagnosticSeverity: String, Codable, Sendable {
    case information
    case warning
    case error
}

/// Fixed diagnostic codes deliberately carry no arbitrary text or numeric
/// sample payload. Add a new reviewed case when another state is needed; do not
/// add associated values containing heart rate, RR, journal, or profile data.
enum SanitizedDiagnosticCode: String, Codable, Sendable {
    case appLaunched
    case persistenceOpened
    case persistenceOpenFailed
    case bluetoothPermissionDenied
    case bluetoothUnavailable
    case sensorScanStarted
    case sensorConnected
    case sensorDisconnected
    case sensorConnectionFailed
    case recordingStarted
    case recordingPaused
    case recordingResumed
    case recordingCompleted
    case recordingInterrupted
    case recordingPersistenceDegraded
    case exportCreated
    case exportFailed
    case deletionCompleted
    case deletionFailed
}

struct SanitizedDiagnosticEvent: Codable, Equatable, Sendable {
    let timestampUTC: Date
    let severity: DiagnosticSeverity
    let code: SanitizedDiagnosticCode
}

/// A bounded, in-memory diagnostic trail whose public recording API cannot
/// accept raw samples or user-authored strings. Persistence is opt-in; callers
/// should normally generate a protected file only when the user asks to share
/// diagnostics and must clean that temporary file afterward.
actor SanitizedDiagnostics {
    private let capacity: Int
    private var events: [SanitizedDiagnosticEvent] = []

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    func record(
        _ code: SanitizedDiagnosticCode,
        severity: DiagnosticSeverity = .information,
        at timestampUTC: Date = Date()
    ) {
        events.append(.init(timestampUTC: timestampUTC, severity: severity, code: code))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func snapshot() -> [SanitizedDiagnosticEvent] {
        events
    }

    func removeAll() {
        events.removeAll(keepingCapacity: true)
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(events)
    }

    func writeProtected(to url: URL) throws {
        try encodedJSON().write(to: url, options: [.atomic, .completeFileProtection])
    }
}
