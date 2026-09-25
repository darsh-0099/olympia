import Combine
import Foundation

struct SensorEventEnvelope: Equatable, Sendable {
    let sequence: UInt64
    let origin: SampleOrigin
    let sensorDeviceID: UUID?
    let event: HeartRateDataEvent
}

enum RecordingStatus: Equatable, Sendable {
    case idle
    case recording(UUID)
    case paused(UUID)
    case ending(UUID)
    case completed(UUID)
    case degraded(UUID, String)
    case failed(String)
}

@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var status: RecordingStatus = .idle
    @Published private(set) var draft: SessionDraft?
    @Published private(set) var lastCommittedSequence: UInt64 = 0

    private let repository: SwiftDataSessionRepository
    private let clock: any SolarClock
    private let batchSize: Int
    private let maximumFlushIntervalNanoseconds: UInt64
    private let flushDeadlineSeconds: Double
    private var pendingEventCount = 0
    private var checkpointNeeded = false
    private var pauseMarkerID: UUID?
    private var recoveryGapID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var flushDeadlineTask: Task<Void, Never>?
    private var lastFlushMonotonicNanoseconds: UInt64
    private var activeSensorDeviceID: UUID?
    private var pendingOrdering: [UUID: SamplePersistenceOrder] = [:]
    private var lastIngressSequence: UInt64 = 0
    private var sessionEventSequence: UInt64 = 0
    private var recordingStartedMonotonicNanoseconds: UInt64?
    private var accumulatedElapsedSeconds: Double = 0
    private let maximumPendingEvents = 250
    private var persistenceLossID: UUID?

    init(repository: SwiftDataSessionRepository, clock: any SolarClock = SystemSolarClock(), batchSize: Int = 25,
         maximumFlushIntervalSeconds: Double = 5) {
        self.repository = repository; self.clock = clock; self.batchSize = max(1, batchSize)
        maximumFlushIntervalNanoseconds = UInt64(max(1, maximumFlushIntervalSeconds) * 1_000_000_000)
        flushDeadlineSeconds = max(1, maximumFlushIntervalSeconds)
        lastFlushMonotonicNanoseconds = clock.monotonicNanoseconds()
    }

    deinit { recoveryTask?.cancel(); flushDeadlineTask?.cancel() }

    func recoverAtLaunch() async {
        do {
            guard let candidate = try await repository.activeSessionCandidate() else { return }
            var recovered = candidate.draft
            guard recovered.origin == .polarH9, recovered.state == .recording else {
                _ = try await repository.salvageIncompleteSessions(at: clock.nowUTC()); return
            }
            let gapID = UUID()
            let gapStart = recovered.interruptions.compactMap { $0.endedAtUTC == nil ? $0.startedAtUTC : nil }
                .reduce(max(candidate.lastDurableEventAtUTC, recovered.startedAtUTC)) { max($0, $1) }
            for marker in recovered.interruptions where marker.endedAtUTC == nil {
                try recovered.endInterruption(id: marker.id, at: gapStart)
            }
            try recovered.beginInterruption(id: gapID, at: gapStart, reason: "App relaunched; waiting for sensor restoration")
            sessionEventSequence = candidate.lastEventSequence
            try await repository.checkpoint(recovered, sensorDeviceID: candidate.sensorDeviceID,
                                            eventSequence: sessionEventSequence)
            recovered.discardCheckpointedSamples()
            activeSensorDeviceID = candidate.sensorDeviceID
            recoveryGapID = gapID; draft = recovered; status = .recording(recovered.id)
            recordingStartedMonotonicNanoseconds = clock.monotonicNanoseconds()
            accumulatedElapsedSeconds = max(0, clock.nowUTC().timeIntervalSince(recovered.startedAtUTC))
            scheduleFlushDeadline()
            recoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.recoveryGapID == gapID else { return }
                await self.salvageRecoveryTimeout(gapID: gapID)
            }
        }
        catch { status = .failed("Could not recover the previous recording: \(error.localizedDescription)") }
    }

    func start(purpose: MeasurementPurpose, origin: SampleOrigin, sensorDeviceID: UUID?) async {
        guard case .idle = status else { return }
        if origin == .polarH9, sensorDeviceID == nil {
            status = .failed("A connected sensor is required before recording can start.")
            return
        }
        do {
            let newDraft = try SessionDraft(purpose: purpose, origin: origin, startedAtUTC: clock.nowUTC())
            try await repository.checkpoint(newDraft, sensorDeviceID: sensorDeviceID)
            draft = newDraft
            activeSensorDeviceID = sensorDeviceID
            pendingEventCount = 0
            sessionEventSequence = 0
            lastFlushMonotonicNanoseconds = clock.monotonicNanoseconds()
            recordingStartedMonotonicNanoseconds = lastFlushMonotonicNanoseconds
            accumulatedElapsedSeconds = 0
            status = .recording(newDraft.id)
            scheduleFlushDeadline()
        } catch { status = .failed("Recording could not start: \(error.localizedDescription)") }
    }

    func ingest(_ envelope: SensorEventEnvelope) async {
        guard var current = draft, current.origin == envelope.origin else { return }
        if current.origin == .polarH9, envelope.sensorDeviceID != activeSensorDeviceID { return }
        let isPaused: Bool
        switch status {
        case .recording(current.id): isPaused = false
        case .degraded(current.id, _): isPaused = current.state == .paused
        case .paused(current.id): isPaused = true
        default: return
        }
        if isPaused {
            switch envelope.event {
            case .heartRate, .rrIntervals: return
            default: break
            }
        }
        do {
            lastIngressSequence = envelope.sequence
            sessionEventSequence &+= 1
            if pendingEventCount >= maximumPendingEvents {
                if persistenceLossID == nil,
                   (current.interruptions.last?.endedAtUTC != nil || current.interruptions.isEmpty) {
                    let at = max(clock.nowUTC(), current.startedAtUTC), id = UUID()
                    try current.beginInterruption(id: id, at: at, reason: "Persistence unavailable; incoming events were dropped")
                    persistenceLossID = id; draft = current
                }
                try await flush(sequence: envelope.sequence)
                return
            }
            let isRecoveryEvidence: Bool
            var didCloseRecoveryGap = false
            switch envelope.event {
            case .heartRate: isRecoveryEvidence = true
            case .rrIntervals(let values): isRecoveryEvidence = !values.isEmpty
            default: isRecoveryEvidence = false
            }
            if let recoveryGapID, isRecoveryEvidence,
               envelope.sensorDeviceID == activeSensorDeviceID,
               let recoveryGap = current.interruptions.first(where: { $0.id == recoveryGapID && $0.endedAtUTC == nil }) {
                let eventTime: Date
                switch envelope.event {
                case .heartRate(let sample): eventTime = sample.receivedAtUTC
                case .rrIntervals(let samples): eventTime = samples.first?.receivedAtUTC ?? clock.nowUTC()
                case .interruptionStarted(_, let at, _), .interruptionEnded(_, let at), .dataLoss(let at, _): eventTime = at
                }
                try current.endInterruption(id: recoveryGapID, at: max(eventTime, recoveryGap.startedAtUTC))
                didCloseRecoveryGap = true
            }
            switch envelope.event {
            case .heartRate(let sample):
                try current.append(sample)
                pendingOrdering[sample.id] = .init(eventSequence: sessionEventSequence, withinPacketIndex: 0)
            case .rrIntervals(let values):
                for (index, value) in values.enumerated() {
                    try current.append(value)
                    pendingOrdering[value.id] = .init(eventSequence: sessionEventSequence, withinPacketIndex: index)
                }
            case .interruptionStarted(let id, let at, let reason):
                if current.interruptions.last?.endedAtUTC != nil || current.interruptions.isEmpty {
                    try current.beginInterruption(id: id, at: max(at, current.startedAtUTC), reason: reason)
                }
            case .interruptionEnded(let id, let at):
                if current.interruptions.contains(where: { $0.id == id && $0.endedAtUTC == nil }) {
                    try current.endInterruption(id: id, at: max(at, current.startedAtUTC))
                }
            case .dataLoss(let at, let reason):
                if current.interruptions.last?.endedAtUTC != nil || current.interruptions.isEmpty {
                    let markerID = UUID(), markerTime = max(at, current.startedAtUTC)
                    try current.beginInterruption(id: markerID, at: markerTime, reason: reason)
                    try current.endInterruption(id: markerID, at: markerTime)
                }
            }
            draft = current
            pendingEventCount += 1
            let nowMonotonic = clock.monotonicNanoseconds()
            let intervalElapsed = nowMonotonic >= lastFlushMonotonicNanoseconds &&
                nowMonotonic - lastFlushMonotonicNanoseconds >= maximumFlushIntervalNanoseconds
            let isBoundary: Bool
            switch envelope.event {
            case .interruptionStarted, .interruptionEnded, .dataLoss: isBoundary = true
            default: isBoundary = false
            }
            if pendingEventCount >= batchSize || intervalElapsed || isBoundary || didCloseRecoveryGap {
                try await flush(sequence: envelope.sequence)
            }
        } catch {
            if case .degraded = status { return }
            status = .degraded(current.id, "Recording needs attention: \(error.localizedDescription)")
        }
    }

    func pause(sequence: UInt64) async {
        guard var current = draft, case .recording(current.id) = status else { return }
        do {
            let markerID = UUID()
            try current.beginPause(id: markerID, at: clock.nowUTC())
            pauseMarkerID = markerID
            flushDeadlineTask?.cancel(); flushDeadlineTask = nil
            draft = current
            checkpointNeeded = true
            try await flush(sequence: sequence)
            status = .paused(current.id)
        }
        catch {
            status = .degraded(current.id, "Could not durably pause: \(error.localizedDescription)")
            scheduleFlushDeadline()
        }
    }

    func resume(sequence: UInt64) async {
        guard var current = draft, case .paused(current.id) = status else { return }
        do {
            guard let pauseMarkerID else { throw SessionDraftError.invalidLifecycle }
            try current.endPause(id: pauseMarkerID, at: clock.nowUTC())
            self.pauseMarkerID = nil
            draft = current
            checkpointNeeded = true
            try await flush(sequence: sequence)
            status = .recording(current.id)
            scheduleFlushDeadline()
        }
        catch {
            status = .degraded(current.id, "Could not durably resume: \(error.localizedDescription)")
            scheduleFlushDeadline()
        }
    }

    func end(sequence: UInt64) async {
        guard var current = draft else { return }
        switch status {
        case .recording(current.id), .paused(current.id), .degraded(current.id, _): break
        default: return
        }
        if current.state == .completed || current.state == .interrupted {
            do { try await flush(sequence: sequence); status = .completed(current.id) }
            catch { status = .degraded(current.id, "Final checkpoint is still pending: \(error.localizedDescription)") }
            return
        }
        status = .ending(current.id)
        flushDeadlineTask?.cancel(); flushDeadlineTask = nil
        do {
            if current.state == .paused, let pauseMarkerID {
                try current.endPause(id: pauseMarkerID, at: clock.nowUTC())
                self.pauseMarkerID = nil
            }
            for marker in current.interruptions where marker.endedAtUTC == nil {
                try current.endInterruption(id: marker.id, at: clock.nowUTC())
            }
            try current.complete(at: clock.nowUTC())
            draft = current
            checkpointNeeded = true
            try await flush(sequence: sequence)
            status = .completed(current.id)
        } catch {
            status = .degraded(current.id, "Final checkpoint is still pending: \(error.localizedDescription)")
            scheduleFlushDeadline()
        }
    }

    func cancel(sequence: UInt64) async {
        guard var current = draft, current.state == .recording || current.state == .paused else { return }
        status = .ending(current.id)
        flushDeadlineTask?.cancel(); flushDeadlineTask = nil
        do {
            if current.state == .paused, let pauseMarkerID {
                try current.endPause(id: pauseMarkerID, at: clock.nowUTC()); self.pauseMarkerID = nil
            }
            let now = max(clock.nowUTC(), current.startedAtUTC)
            for marker in current.interruptions where marker.endedAtUTC == nil {
                try current.endInterruption(id: marker.id, at: now)
            }
            try current.markInterrupted(at: now, marker: .init(startedAtUTC: now, endedAtUTC: now,
                                                               reason: "User cancelled before completion"))
            draft = current; checkpointNeeded = true
            try await flush(sequence: sequence)
            status = .completed(current.id)
        } catch {
            status = .degraded(current.id, "Cancellation is still saving: \(error.localizedDescription)")
            scheduleFlushDeadline()
        }
    }

    func resetAfterSummary() {
        if case .completed = status {
            draft = nil; recordingStartedMonotonicNanoseconds = nil
            accumulatedElapsedSeconds = 0; status = .idle
        }
    }

    func acknowledgeFailure() {
        guard case .failed = status, draft == nil else { return }
        recordingStartedMonotonicNanoseconds = nil; accumulatedElapsedSeconds = 0; status = .idle
    }

    var elapsedRecordingSeconds: Double {
        guard let start = recordingStartedMonotonicNanoseconds else { return 0 }
        let now = clock.monotonicNanoseconds()
        guard now >= start else { return 0 }
        return accumulatedElapsedSeconds + Double(now - start) / 1_000_000_000
    }

    func resetAfterDataDeletion() {
        guard draft?.state != .recording && draft?.state != .paused else { return }
        recoveryTask?.cancel(); flushDeadlineTask?.cancel()
        recoveryTask = nil; flushDeadlineTask = nil
        draft = nil; status = .idle
        pendingEventCount = 0; checkpointNeeded = false
        pendingOrdering.removeAll(keepingCapacity: false)
        pauseMarkerID = nil; recoveryGapID = nil; persistenceLossID = nil
        activeSensorDeviceID = nil; recordingStartedMonotonicNanoseconds = nil
        accumulatedElapsedSeconds = 0; sessionEventSequence = 0
    }

    func flushForBackground() async {
        guard pendingEventCount > 0 || checkpointNeeded else { return }
        do { try await flush(sequence: lastIngressSequence) }
        catch {
            if let draft {
                status = .degraded(draft.id, "Background checkpoint is retrying: \(error.localizedDescription)")
                scheduleFlushDeadline()
            } else {
                status = .failed("Background checkpoint failed: \(error.localizedDescription)")
            }
        }
    }

    private func flush(sequence: UInt64) async throws {
        guard var checkpointDraft = draft else { return }
        if let persistenceLossID,
           checkpointDraft.interruptions.contains(where: { $0.id == persistenceLossID && $0.endedAtUTC == nil }) {
            try checkpointDraft.endInterruption(id: persistenceLossID,
                                                at: max(clock.nowUTC(), checkpointDraft.startedAtUTC))
        }
        var finalError: Error?
        for attempt in 0..<3 {
            do {
                try await repository.checkpoint(checkpointDraft, sensorDeviceID: activeSensorDeviceID, ordering: pendingOrdering,
                                                eventSequence: sessionEventSequence)
                finalError = nil
                break
            } catch {
                finalError = error
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(200 * (attempt + 1))) }
            }
        }
        if let finalError {
            status = .degraded(checkpointDraft.id, "Local writes are retrying; capture is buffered and bounded.")
            throw finalError
        }
        var boundedDraft = checkpointDraft
        boundedDraft.discardCheckpointedSamples()
        self.draft = boundedDraft
        pendingOrdering.removeAll(keepingCapacity: true)
        pendingEventCount = 0
        checkpointNeeded = false
        if let recoveryGapID,
           boundedDraft.interruptions.contains(where: { $0.id == recoveryGapID && $0.endedAtUTC != nil }) {
            self.recoveryGapID = nil
            recoveryTask?.cancel(); recoveryTask = nil
        }
        persistenceLossID = nil
        lastCommittedSequence = sequence
        lastFlushMonotonicNanoseconds = clock.monotonicNanoseconds()
        if case .degraded = status {
            switch checkpointDraft.state {
            case .recording: status = .recording(checkpointDraft.id)
            case .paused: status = .paused(checkpointDraft.id)
            case .completed: status = .completed(checkpointDraft.id)
            case .interrupted: status = .failed("The interrupted recording was safely salvaged.")
            }
        }
    }

    private func scheduleFlushDeadline() {
        flushDeadlineTask?.cancel()
        let deadlineSeconds = flushDeadlineSeconds
        flushDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(deadlineSeconds))
            guard !Task.isCancelled, let self else { return }
            if self.pendingEventCount > 0 || self.checkpointNeeded {
                do { try await self.flush(sequence: self.lastIngressSequence) }
                catch { if case .degraded = self.status {} else { self.status = .failed("Timed checkpoint failed: \(error.localizedDescription)") } }
            }
            switch self.status {
            case .recording, .degraded: self.scheduleFlushDeadline()
            default: break
            }
        }
    }

    private func salvageRecoveryTimeout(gapID: UUID) async {
        guard var current = draft else { return }
        switch status {
        case .recording(current.id), .degraded(current.id, _): break
        default: return
        }
        do {
            let now = max(clock.nowUTC(), current.startedAtUTC)
            if current.interruptions.contains(where: { $0.id == gapID && $0.endedAtUTC == nil }) {
                try current.endInterruption(id: gapID, at: now)
            }
            let terminal = InterruptionMarker(startedAtUTC: now, endedAtUTC: now,
                                              reason: "Sensor restoration timed out")
            try current.markInterrupted(at: now, marker: terminal)
            draft = current
            checkpointNeeded = true
            try await flush(sequence: lastIngressSequence)
            status = .failed("The interrupted recording was safely salvaged.")
        } catch {
            status = .degraded(current.id, "Interrupted-session salvage is still pending: \(error.localizedDescription)")
            scheduleFlushDeadline()
        }
    }
}
