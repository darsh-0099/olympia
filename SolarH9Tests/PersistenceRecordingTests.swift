import XCTest
@testable import SolarH9

@MainActor
final class PersistenceRecordingTests: XCTestCase {
    func testRepositoryRoundTripAndRealOnlyDefault() async throws {
        let repository = try makeRepository()
        let real = try SessionDraft(purpose: .exerciseSession, origin: .polarH9, startedAtUTC: Date())
        let demo = try SessionDraft(purpose: .exerciseSession, origin: .simulator, startedAtUTC: Date())
        try await repository.save(real); try await repository.save(demo)
        let realSessions = try await repository.sessions()
        let allSessions = try await repository.sessions(scope: .all)
        let loadedReal = try await repository.session(id: real.id)
        XCTAssertEqual(realSessions.map(\.id), [real.id])
        XCTAssertEqual(Set(allSessions.map(\.id)), Set([real.id, demo.id]))
        XCTAssertEqual(loadedReal, real)
    }

    func testBaselineAdapterCannotSeeDemoOrExerciseSessions() async throws {
        let repository = try makeRepository()
        let start = Date(timeIntervalSince1970: 10)
        var eligible = try SessionDraft(purpose: .restingCheckIn, origin: .polarH9, startedAtUTC: start)
        for index in 0..<180 {
            try eligible.append(HeartRateSampleValue(beatsPerMinute: 60, receivedAtUTC: start.addingTimeInterval(Double(index)),
                                                     receivedMonotonicNanoseconds: UInt64(index), origin: .polarH9))
            try eligible.append(RRIntervalValue(rawTicks1024: index.isMultiple(of: 2) ? 1_024 : 1_126,
                                                receivedAtUTC: start.addingTimeInterval(Double(index)),
                                                receivedMonotonicNanoseconds: UInt64(index), derivedBeatTimeUTC: nil,
                                                derivedBeatMonotonicNanoseconds: nil, origin: .polarH9))
        }
        try eligible.complete(at: start.addingTimeInterval(240))
        var demo = try SessionDraft(purpose: .restingCheckIn, origin: .simulator, startedAtUTC: start)
        try demo.complete(at: start.addingTimeInterval(240))
        var exercise = try SessionDraft(purpose: .exerciseSession, origin: .polarH9, startedAtUTC: start)
        try exercise.complete(at: start.addingTimeInterval(240))
        var poor = try SessionDraft(purpose: .restingCheckIn, origin: .polarH9, startedAtUTC: start)
        for index in 0..<180 {
            try poor.append(HeartRateSampleValue(beatsPerMinute: 60, receivedAtUTC: start.addingTimeInterval(Double(index)),
                                                 receivedMonotonicNanoseconds: UInt64(index), origin: .polarH9))
            try poor.append(RRIntervalValue(rawTicks1024: 1, receivedAtUTC: start.addingTimeInterval(Double(index)),
                                            receivedMonotonicNanoseconds: UInt64(index), derivedBeatTimeUTC: nil,
                                            derivedBeatMonotonicNanoseconds: nil, origin: .polarH9))
        }
        try poor.complete(at: start.addingTimeInterval(240))
        try await repository.save(eligible); try await repository.save(demo); try await repository.save(exercise)
        try await repository.save(poor)
        let baseline = try await repository.baselineEligibleSessions()
        XCTAssertEqual(baseline.map(\.id), [eligible.id])
    }

    func testCheckpointIsIdempotentAndDeleteCascadesOwnedGraph() async throws {
        let repository = try makeRepository()
        var draft = try SessionDraft(purpose: .exerciseSession, origin: .polarH9, startedAtUTC: Date())
        let sample = HeartRateSampleValue(beatsPerMinute: 70, receivedAtUTC: Date(),
                                          receivedMonotonicNanoseconds: 1, origin: .polarH9)
        try draft.append(sample)
        try await repository.checkpoint(draft); try await repository.checkpoint(draft)
        let checkpointed = try await repository.session(id: draft.id)
        XCTAssertEqual(checkpointed?.heartRates.count, 1)
        try await repository.deleteSession(id: draft.id)
        let deleted = try await repository.session(id: draft.id)
        XCTAssertNil(deleted)
    }

    func testSalvageIsIdempotent() async throws {
        let repository = try makeRepository()
        let draft = try SessionDraft(purpose: .exerciseSession, origin: .polarH9,
                                     startedAtUTC: Date(timeIntervalSince1970: 100))
        try await repository.checkpoint(draft)
        let first = try await repository.salvageIncompleteSessions(at: Date(timeIntervalSince1970: 200))
        let once = try await repository.session(id: draft.id)
        let second = try await repository.salvageIncompleteSessions(at: Date(timeIntervalSince1970: 300))
        let twice = try await repository.session(id: draft.id)
        XCTAssertEqual(first, [draft.id]); XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(twice, once)
        XCTAssertEqual(once?.state, .interrupted)
        let active = try await repository.activeSessionCandidate()
        XCTAssertNil(active)
    }

    func testVersionedDiskStoreReopensAndPreservesMultiRROrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("SolarH9.store")
        let sessionID = UUID(), received = Date(timeIntervalSince1970: 1_000)
        let values: [UInt16] = [1_024, 900, 1_100]
        do {
            let repository = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(storeURL: url))
            var draft = try SessionDraft(id: sessionID, purpose: .exerciseSession, origin: .polarH9,
                                         startedAtUTC: received)
            let samples = values.map {
                RRIntervalValue(rawTicks1024: $0, receivedAtUTC: received, receivedMonotonicNanoseconds: 99,
                                derivedBeatTimeUTC: nil, derivedBeatMonotonicNanoseconds: nil, origin: .polarH9)
            }
            for sample in samples { try draft.append(sample) }
            let ordering = Dictionary(uniqueKeysWithValues: samples.enumerated().map {
                ($0.element.id, SamplePersistenceOrder(eventSequence: 7, withinPacketIndex: $0.offset))
            })
            try await repository.checkpoint(draft, sensorDeviceID: UUID(), ordering: ordering)
        }
        let reopened = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(storeURL: url))
        let loaded = try await reopened.session(id: sessionID)
        XCTAssertEqual(loaded?.rrIntervals.map(\.rawTicks1024), values)
    }

    func testReopenRecoveryAppendsAfterPriorSequenceAndRestoresPauses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("SolarH9.store"), sessionID = UUID(), deviceID = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        do {
            let repository = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(storeURL: url))
            var draft = try SessionDraft(id: sessionID, purpose: .exerciseSession, origin: .polarH9, startedAtUTC: start)
            let first = HeartRateSampleValue(beatsPerMinute: 70, receivedAtUTC: start,
                                             receivedMonotonicNanoseconds: 1, origin: .polarH9)
            try draft.append(first)
            try await repository.checkpoint(draft, sensorDeviceID: deviceID,
                ordering: [first.id: .init(eventSequence: 41, withinPacketIndex: 0)], eventSequence: 41)
        }
        let repository = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(storeURL: url))
        let activeCandidate = try await repository.activeSessionCandidate()
        let candidate = try XCTUnwrap(activeCandidate)
        XCTAssertEqual(candidate.lastEventSequence, 41)
        var recovered = candidate.draft
        let pauseID = UUID()
        try recovered.beginPause(id: pauseID, at: start.addingTimeInterval(2))
        try recovered.endPause(id: pauseID, at: start.addingTimeInterval(3))
        let second = HeartRateSampleValue(beatsPerMinute: 80, receivedAtUTC: start.addingTimeInterval(4),
                                          receivedMonotonicNanoseconds: 2, origin: .polarH9)
        try recovered.append(second)
        try await repository.checkpoint(recovered, sensorDeviceID: deviceID,
            ordering: [second.id: .init(eventSequence: 42, withinPacketIndex: 0)], eventSequence: 42)
        let storedSession = try await repository.session(id: sessionID)
        let loaded = try XCTUnwrap(storedSession)
        XCTAssertEqual(loaded.heartRates.map(\.beatsPerMinute), [70, 80])
        XCTAssertEqual(loaded.pauses, [.init(id: pauseID, startedAtUTC: start.addingTimeInterval(2),
                                            endedAtUTC: start.addingTimeInterval(3))])
    }

    func testCorruptStoreFailureDoesNotDeleteStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("SolarH9.store")
        try Data("not a sqlite store".utf8).write(to: url)
        XCTAssertThrowsError(try SolarPersistence.makeContainer(storeURL: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordingRejectsMixedOriginAndFlushesBatches() async throws {
        let repository = try makeRepository()
        let clock = FixedClock(now: Date(timeIntervalSince1970: 100), ticks: 1)
        let controller = RecordingController(repository: repository, clock: clock, batchSize: 1)
        let deviceID = UUID()
        await controller.start(purpose: .exerciseSession, origin: .polarH9, sensorDeviceID: deviceID)
        let id = try XCTUnwrap(controller.draft?.id)
        let simulated = HeartRateSampleValue(beatsPerMinute: 99, receivedAtUTC: clock.nowUTC(),
                                             receivedMonotonicNanoseconds: 1, origin: .simulator)
        await controller.ingest(.init(sequence: 1, origin: .simulator, sensorDeviceID: nil, event: .heartRate(simulated)))
        XCTAssertEqual(controller.draft?.heartRates.count, 0)
        let real = HeartRateSampleValue(beatsPerMinute: 70, receivedAtUTC: clock.nowUTC(),
                                        receivedMonotonicNanoseconds: 2, origin: .polarH9)
        await controller.ingest(.init(sequence: 2, origin: .polarH9, sensorDeviceID: deviceID, event: .heartRate(real)))
        let stored = try await repository.session(id: id)
        XCTAssertEqual(stored?.heartRates.map(\.beatsPerMinute), [70])
    }

    func testRecordingPersistsMultiRRGapPauseAndTerminalState() async throws {
        let repository = try makeRepository()
        let clock = FixedClock(now: Date(timeIntervalSince1970: 500), ticks: 10)
        let controller = RecordingController(repository: repository, clock: clock, batchSize: 50)
        let deviceID = UUID()
        await controller.start(purpose: .exerciseSession, origin: .polarH9, sensorDeviceID: deviceID)
        let sessionID = try XCTUnwrap(controller.draft?.id)
        let gapID = UUID()
        await controller.ingest(.init(sequence: 1, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .interruptionStarted(id: gapID, at: clock.now, reason: "Transport gap")))
        await controller.ingest(.init(sequence: 2, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .interruptionEnded(id: gapID, at: clock.now)))
        let rr = [rr(1_024, tick: 11), rr(900, tick: 12)]
        await controller.ingest(.init(sequence: 3, origin: .polarH9, sensorDeviceID: deviceID, event: .rrIntervals(rr)))
        await controller.pause(sequence: 4)
        let pausedGapID = UUID()
        await controller.ingest(.init(sequence: 4, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .interruptionStarted(id: pausedGapID, at: clock.now, reason: "Gap while paused")))
        await controller.ingest(.init(sequence: 4, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .interruptionEnded(id: pausedGapID, at: clock.now)))
        await controller.ingest(.init(sequence: 5, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .heartRate(hr(200, tick: 13))))
        await controller.resume(sequence: 5)
        await controller.ingest(.init(sequence: 6, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .heartRate(hr(75, tick: 14))))
        await controller.end(sequence: 7)
        let stored = try await repository.session(id: sessionID)
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.rrIntervals.map(\.rawTicks1024), [1_024, 900])
        XCTAssertEqual(stored?.heartRates.map(\.beatsPerMinute), [75])
        XCTAssertEqual(stored?.interruptions.count, 2)
        XCTAssertTrue(stored?.interruptions.allSatisfy { $0.endedAtUTC != nil } == true)
    }

    func testTimedFlushCommitsWithoutAnotherSensorEvent() async throws {
        let repository = try makeRepository()
        let clock = FixedClock(now: Date(timeIntervalSince1970: 700), ticks: 1)
        let controller = RecordingController(repository: repository, clock: clock, batchSize: 50,
                                             maximumFlushIntervalSeconds: 1)
        let deviceID = UUID()
        await controller.start(purpose: .exerciseSession, origin: .polarH9, sensorDeviceID: deviceID)
        let id = try XCTUnwrap(controller.draft?.id)
        await controller.ingest(.init(sequence: 1, origin: .polarH9, sensorDeviceID: deviceID,
                                      event: .heartRate(hr(80, tick: 2))))
        try await Task.sleep(for: .milliseconds(1_100))
        let stored = try await repository.session(id: id)
        XCTAssertEqual(stored?.heartRates.map(\.beatsPerMinute), [80])
        await controller.end(sequence: 2)
    }

    func testRecoveryClosesOnlyForSampleFromCheckpointedDevice() async throws {
        let repository = try makeRepository(), expectedDevice = UUID()
        let start = Date(timeIntervalSince1970: 900)
        let draft = try SessionDraft(purpose: .exerciseSession, origin: .polarH9, startedAtUTC: start)
        try await repository.checkpoint(draft, sensorDeviceID: expectedDevice)
        let controller = RecordingController(repository: repository, clock: FixedClock(now: start, ticks: 1))
        await controller.recoverAtLaunch()
        let gapID = try XCTUnwrap(controller.draft?.interruptions.last?.id)
        await controller.ingest(.init(sequence: 1, origin: .polarH9, sensorDeviceID: expectedDevice,
                                      event: .dataLoss(at: start, reason: "Buffered loss")))
        XCTAssertNil(controller.draft?.interruptions.first(where: { $0.id == gapID })?.endedAtUTC)
        let recoveredSample = HeartRateSampleValue(beatsPerMinute: 70, receivedAtUTC: start,
                                                   receivedMonotonicNanoseconds: 2, origin: .polarH9)
        await controller.ingest(.init(sequence: 2, origin: .polarH9, sensorDeviceID: UUID(),
                                      event: .heartRate(recoveredSample)))
        XCTAssertNil(controller.draft?.interruptions.first(where: { $0.id == gapID })?.endedAtUTC)
        await controller.ingest(.init(sequence: 3, origin: .polarH9, sensorDeviceID: expectedDevice,
                                      event: .heartRate(recoveredSample)))
        XCTAssertNotNil(controller.draft?.interruptions.first(where: { $0.id == gapID })?.endedAtUTC)
        await controller.end(sequence: 4)
    }

    private func makeRepository() throws -> SwiftDataSessionRepository {
        SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(inMemory: true))
    }

    private func hr(_ bpm: Int, tick: UInt64) -> HeartRateSampleValue {
        .init(beatsPerMinute: bpm, receivedAtUTC: Date(timeIntervalSince1970: 500),
              receivedMonotonicNanoseconds: tick, origin: .polarH9)
    }

    private func rr(_ ticks: UInt16, tick: UInt64) -> RRIntervalValue {
        .init(rawTicks1024: ticks, receivedAtUTC: Date(timeIntervalSince1970: 500),
              receivedMonotonicNanoseconds: tick, derivedBeatTimeUTC: nil,
              derivedBeatMonotonicNanoseconds: nil, origin: .polarH9)
    }
}

private struct FixedClock: SolarClock {
    let now: Date
    let ticks: UInt64
    func nowUTC() -> Date { now }
    func monotonicNanoseconds() -> UInt64 { ticks }
}
