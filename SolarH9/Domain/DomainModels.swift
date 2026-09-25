import Foundation

enum SampleOrigin: String, Codable, CaseIterable, Sendable {
    case polarH9
    case simulator
}

enum MeasurementPurpose: String, Codable, CaseIterable, Sendable {
    case restingCheckIn
    case exerciseSession
}

enum SessionState: String, Codable, Sendable {
    case recording
    case paused
    case completed
    case interrupted
}

enum SessionDraftError: Error, Equatable {
    case sampleOriginMismatch
    case invalidLifecycle
}

struct HeartRateSampleValue: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let beatsPerMinute: Int
    let receivedAtUTC: Date
    let receivedMonotonicNanoseconds: UInt64
    let origin: SampleOrigin

    init(
        id: UUID = UUID(),
        beatsPerMinute: Int,
        receivedAtUTC: Date,
        receivedMonotonicNanoseconds: UInt64,
        origin: SampleOrigin
    ) {
        self.id = id
        self.beatsPerMinute = beatsPerMinute
        self.receivedAtUTC = receivedAtUTC
        self.receivedMonotonicNanoseconds = receivedMonotonicNanoseconds
        self.origin = origin
    }
}

struct RRIntervalValue: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let rawTicks1024: UInt16
    let receivedAtUTC: Date
    let receivedMonotonicNanoseconds: UInt64
    let derivedBeatTimeUTC: Date?
    let derivedBeatMonotonicNanoseconds: UInt64?
    let origin: SampleOrigin

    var milliseconds: Double {
        Double(rawTicks1024) * 1_000.0 / 1_024.0
    }

    init(
        id: UUID = UUID(),
        rawTicks1024: UInt16,
        receivedAtUTC: Date,
        receivedMonotonicNanoseconds: UInt64,
        derivedBeatTimeUTC: Date?,
        derivedBeatMonotonicNanoseconds: UInt64?,
        origin: SampleOrigin
    ) {
        self.id = id
        self.rawTicks1024 = rawTicks1024
        self.receivedAtUTC = receivedAtUTC
        self.receivedMonotonicNanoseconds = receivedMonotonicNanoseconds
        self.derivedBeatTimeUTC = derivedBeatTimeUTC
        self.derivedBeatMonotonicNanoseconds = derivedBeatMonotonicNanoseconds
        self.origin = origin
    }
}

struct InterruptionMarker: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startedAtUTC: Date
    let endedAtUTC: Date?
    let reason: String

    init(id: UUID = UUID(), startedAtUTC: Date, endedAtUTC: Date?, reason: String) {
        self.id = id
        self.startedAtUTC = startedAtUTC
        self.endedAtUTC = endedAtUTC
        self.reason = reason
    }
}

struct PauseIntervalValue: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startedAtUTC: Date
    let endedAtUTC: Date?
}

struct SessionDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let purpose: MeasurementPurpose
    let origin: SampleOrigin
    let startedAtUTC: Date
    private(set) var endedAtUTC: Date?
    private(set) var state: SessionState
    private(set) var heartRates: [HeartRateSampleValue]
    private(set) var rrIntervals: [RRIntervalValue]
    private(set) var interruptions: [InterruptionMarker]
    private(set) var pauses: [PauseIntervalValue]

    init(
        id: UUID = UUID(),
        purpose: MeasurementPurpose,
        origin: SampleOrigin,
        startedAtUTC: Date,
        endedAtUTC: Date? = nil,
        state: SessionState = .recording,
        heartRates: [HeartRateSampleValue] = [],
        rrIntervals: [RRIntervalValue] = [],
        interruptions: [InterruptionMarker] = [],
        pauses: [PauseIntervalValue] = []
    ) throws {
        guard heartRates.allSatisfy({ $0.origin == origin }) && rrIntervals.allSatisfy({ $0.origin == origin }) else {
            throw SessionDraftError.sampleOriginMismatch
        }
        let isTerminal = state == .completed || state == .interrupted
        guard isTerminal == (endedAtUTC != nil), endedAtUTC.map({ $0 >= startedAtUTC }) ?? true else {
            throw SessionDraftError.invalidLifecycle
        }
        if state == .interrupted && interruptions.isEmpty {
            throw SessionDraftError.invalidLifecycle
        }
        guard Self.interruptionsAreValid(
            interruptions,
            sessionStart: startedAtUTC,
            sessionEnd: endedAtUTC,
            requiresClosedMarkers: isTerminal
        ) else {
            throw SessionDraftError.invalidLifecycle
        }
        guard Self.pausesAreValid(pauses, sessionStart: startedAtUTC, sessionEnd: endedAtUTC,
                                  requiresClosedIntervals: isTerminal) else {
            throw SessionDraftError.invalidLifecycle
        }
        let openPauseCount = pauses.filter { $0.endedAtUTC == nil }.count
        guard (state == .paused && openPauseCount == 1) || (state != .paused && openPauseCount == 0) else {
            throw SessionDraftError.invalidLifecycle
        }
        self.id = id
        self.purpose = purpose
        self.origin = origin
        self.startedAtUTC = startedAtUTC
        self.endedAtUTC = endedAtUTC
        self.state = state
        self.heartRates = heartRates
        self.rrIntervals = rrIntervals
        self.interruptions = interruptions
        self.pauses = pauses
    }

    mutating func append(_ sample: HeartRateSampleValue) throws {
        guard state == .recording else { throw SessionDraftError.invalidLifecycle }
        guard sample.origin == origin else { throw SessionDraftError.sampleOriginMismatch }
        heartRates.append(sample)
    }

    mutating func append(_ sample: RRIntervalValue) throws {
        guard state == .recording else { throw SessionDraftError.invalidLifecycle }
        guard sample.origin == origin else { throw SessionDraftError.sampleOriginMismatch }
        rrIntervals.append(sample)
    }

    mutating func beginInterruption(id: UUID = UUID(), at startUTC: Date, reason: String) throws {
        guard state == .recording || state == .paused else { throw SessionDraftError.invalidLifecycle }
        let marker = InterruptionMarker(id: id, startedAtUTC: startUTC, endedAtUTC: nil, reason: reason)
        guard Self.interruptionsAreValid(
            interruptions + [marker],
            sessionStart: startedAtUTC,
            sessionEnd: nil,
            requiresClosedMarkers: false
        ) else {
            throw SessionDraftError.invalidLifecycle
        }
        interruptions.append(marker)
    }

    mutating func endInterruption(id: UUID, at endUTC: Date) throws {
        guard state == .recording || state == .paused,
              let index = interruptions.lastIndex(where: { $0.id == id && $0.endedAtUTC == nil }) else {
            throw SessionDraftError.invalidLifecycle
        }
        let open = interruptions[index]
        let closed = InterruptionMarker(id: open.id, startedAtUTC: open.startedAtUTC, endedAtUTC: endUTC, reason: open.reason)
        var proposed = interruptions
        proposed[index] = closed
        guard Self.interruptionsAreValid(
            proposed,
            sessionStart: startedAtUTC,
            sessionEnd: nil,
            requiresClosedMarkers: false
        ) else {
            throw SessionDraftError.invalidLifecycle
        }
        interruptions = proposed
    }

    mutating func pause() throws {
        guard state == .recording else { throw SessionDraftError.invalidLifecycle }
        state = .paused
    }

    mutating func beginPause(id: UUID = UUID(), at startUTC: Date) throws {
        guard state == .recording, startUTC >= startedAtUTC,
              pauses.last?.endedAtUTC != nil || pauses.isEmpty else { throw SessionDraftError.invalidLifecycle }
        let proposed = pauses + [.init(id: id, startedAtUTC: startUTC, endedAtUTC: nil)]
        guard Self.pausesAreValid(proposed, sessionStart: startedAtUTC, sessionEnd: nil,
                                  requiresClosedIntervals: false) else { throw SessionDraftError.invalidLifecycle }
        pauses = proposed
        try pause()
    }

    mutating func resume() throws {
        guard state == .paused else { throw SessionDraftError.invalidLifecycle }
        state = .recording
    }

    mutating func endPause(id: UUID, at endUTC: Date) throws {
        guard state == .paused, let index = pauses.lastIndex(where: { $0.id == id && $0.endedAtUTC == nil }),
              endUTC >= pauses[index].startedAtUTC else { throw SessionDraftError.invalidLifecycle }
        let open = pauses[index]
        pauses[index] = .init(id: open.id, startedAtUTC: open.startedAtUTC, endedAtUTC: endUTC)
        try resume()
    }

    mutating func complete(at endUTC: Date) throws {
        guard state == .recording || state == .paused,
              endUTC >= startedAtUTC,
              Self.interruptionsAreValid(
                interruptions,
                sessionStart: startedAtUTC,
                sessionEnd: endUTC,
                requiresClosedMarkers: true
              ), Self.pausesAreValid(pauses, sessionStart: startedAtUTC, sessionEnd: endUTC,
                                     requiresClosedIntervals: true) else {
            throw SessionDraftError.invalidLifecycle
        }
        state = .completed
        endedAtUTC = endUTC
    }

    mutating func markInterrupted(at endUTC: Date, marker: InterruptionMarker) throws {
        let proposed = interruptions + [marker]
        guard state == .recording || state == .paused,
              endUTC >= startedAtUTC,
              Self.interruptionsAreValid(
                proposed,
                sessionStart: startedAtUTC,
                sessionEnd: endUTC,
                requiresClosedMarkers: true
              ), Self.pausesAreValid(pauses, sessionStart: startedAtUTC, sessionEnd: endUTC,
                                     requiresClosedIntervals: true) else {
            throw SessionDraftError.invalidLifecycle
        }
        interruptions = proposed
        state = .interrupted
        endedAtUTC = endUTC
    }

    var passesRestingContextPrecheck: Bool {
        purpose == .restingCheckIn &&
        origin == .polarH9 &&
        state == .completed &&
        interruptions.isEmpty
    }

    /// Recording persistence calls this only after a durable checkpoint. The
    /// session header and interruption timeline remain in memory while raw rows
    /// live in SwiftData, preventing a long session from retaining every sample.
    mutating func discardCheckpointedSamples() {
        guard state == .recording || state == .paused else { return }
        heartRates.removeAll(keepingCapacity: true)
        rrIntervals.removeAll(keepingCapacity: true)
    }

    private enum CodingKeys: String, CodingKey {
        case id, purpose, origin, startedAtUTC, endedAtUTC, state, heartRates, rrIntervals, interruptions, pauses
    }

    private static func interruptionsAreValid(
        _ markers: [InterruptionMarker],
        sessionStart: Date,
        sessionEnd: Date?,
        requiresClosedMarkers: Bool
    ) -> Bool {
        for (index, marker) in markers.enumerated() {
            guard !marker.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  marker.startedAtUTC >= sessionStart else { return false }
            if index > 0 {
                guard let previousEnd = markers[index - 1].endedAtUTC,
                      marker.startedAtUTC >= previousEnd else { return false }
            }
            if requiresClosedMarkers && marker.endedAtUTC == nil { return false }
            if let markerEnd = marker.endedAtUTC {
                guard markerEnd >= marker.startedAtUTC else { return false }
                if let sessionEnd, markerEnd > sessionEnd { return false }
            }
        }
        return true
    }

    private static func pausesAreValid(
        _ intervals: [PauseIntervalValue], sessionStart: Date, sessionEnd: Date?, requiresClosedIntervals: Bool
    ) -> Bool {
        for (index, interval) in intervals.enumerated() {
            guard interval.startedAtUTC >= sessionStart else { return false }
            if index > 0 {
                guard let priorEnd = intervals[index - 1].endedAtUTC,
                      interval.startedAtUTC >= priorEnd else { return false }
            }
            if requiresClosedIntervals && interval.endedAtUTC == nil { return false }
            if let end = interval.endedAtUTC {
                guard end >= interval.startedAtUTC else { return false }
                if let sessionEnd, end > sessionEnd { return false }
            }
        }
        return true
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: values.decode(UUID.self, forKey: .id),
                purpose: values.decode(MeasurementPurpose.self, forKey: .purpose),
                origin: values.decode(SampleOrigin.self, forKey: .origin),
                startedAtUTC: values.decode(Date.self, forKey: .startedAtUTC),
                endedAtUTC: values.decodeIfPresent(Date.self, forKey: .endedAtUTC),
                state: values.decode(SessionState.self, forKey: .state),
                heartRates: values.decode([HeartRateSampleValue].self, forKey: .heartRates),
                rrIntervals: values.decode([RRIntervalValue].self, forKey: .rrIntervals),
                interruptions: values.decode([InterruptionMarker].self, forKey: .interruptions),
                pauses: values.decodeIfPresent([PauseIntervalValue].self, forKey: .pauses) ?? []
            )
        } catch let error as SessionDraftError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid session draft: \(error)"))
        }
    }
}
