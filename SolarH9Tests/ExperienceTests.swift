import XCTest
@testable import SolarH9

@MainActor
final class ExperienceTests: XCTestCase {
    func testDiscardWorkoutRemovesLoggedSetsAndSession() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        let engine = OlympiaWorkoutEngine(store: store)
        let workout = OlympiaWorkoutTemplate(name: "Push", exercises: [
            OlympiaExercise(name: "Bench Press", sets: 3, restSeconds: 90)
        ])
        engine.start(workout)
        engine.beginNow()
        engine.completeSet(weightPounds: 100, reps: 12)
        XCTAssertEqual(store.sessions.first?.completedSets.count, 1)
        engine.cancel()
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(engine.secondsRemaining, 0)
    }

    func testFinishWorkoutKeepsPartialSession() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        let engine = OlympiaWorkoutEngine(store: store)
        engine.start(OlympiaWorkoutTemplate(name: "Push", exercises: [
            OlympiaExercise(name: "Bench Press", sets: 3, restSeconds: 90)
        ]))
        engine.beginNow()
        engine.completeSet(weightPounds: 100, reps: 12)
        engine.finish()
        XCTAssertFalse(engine.isActive)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.status, "partial")
        XCTAssertEqual(store.sessions.first?.completedSets.first?.reps, 12)
    }

    func testNoteImportPreservesSlashSetsAndFinalSetOverride() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        let report = OlympiaNoteImporter.importWorkouts("""
        Push 7/28/25:
        1. Bench Press - 17/15/15 - 85lbs
        2. Lateral Raises - 4 sets - 12 reps (Last set 15) - 19lbs
        """, into: store)
        XCTAssertEqual(report.sets, 7)
        let sets = try XCTUnwrap(store.sessions.first).completedSets
        XCTAssertEqual(sets.prefix(3).compactMap(\.reps), [17, 15, 15])
        XCTAssertEqual(sets.suffix(4).compactMap(\.reps), [12, 12, 12, 15])
        XCTAssertEqual(sets.prefix(3).compactMap(\.weightPounds), [85, 85, 85])
    }

    func testZoneLadderRepresentsEveryZoneAndTargetRelationship() {
        for zone in 1...5 {
            let snapshot = SolarZoneSnapshot(beatsPerMinute: 80 + zone * 20, currentZone: zone, targetZone: 3)
            XCTAssertEqual(snapshot.currentZone, zone)
            XCTAssertEqual(snapshot.targetState, zone < 3 ? .belowTarget : zone == 3 ? .inTarget : .aboveTarget)
        }
    }

    func testZoneLadderHasExplicitUnavailableState() {
        let snapshot = SolarZoneSnapshot(beatsPerMinute: nil, currentZone: nil, targetZone: 2)
        XCTAssertEqual(snapshot.targetState, .noTarget)
    }

    func testLiveActivityStateCoversGoodPoorAndDisconnectedSignal() {
        let qualities: [HeartRateActivityAttributes.ContentState.ConnectionQuality] = [.good, .poor, .disconnected]
        XCTAssertEqual(qualities.map(\.label), ["Good signal", "Signal delayed", "Disconnected"])
    }

    func testMonitoringAndWorkoutAreDistinctLiveActivityModes() {
        XCTAssertNotEqual(HeartRateActivityAttributes.Mode.monitoring, .workout)
        XCTAssertEqual(HeartRateActivityAttributes.Mode.monitoring.title, "Monitoring")
        XCTAssertEqual(HeartRateActivityAttributes.Mode.workout.title, "Workout")
    }

    func testPassiveMonitoringStartsWithoutRecordingAndWorkoutTransitionStartsPersistedSession() async throws {
        let defaults = UserDefaults(suiteName: "test.monitoring.\(UUID().uuidString)")!
        let repository = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(inMemory: true))
        let recording = RecordingController(repository: repository)
        let coordinator = SensorCoordinator(sensor: PolarH9Client(defaults: defaults), recording: recording)
        await coordinator.select(.simulator)
        await coordinator.toggleDemo()
        await coordinator.startMonitoring()
        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertNil(recording.draft)
        XCTAssertFalse(coordinator.hasActiveRecording)

        await coordinator.startWorkout()
        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertTrue(coordinator.hasActiveRecording)
        XCTAssertEqual(recording.draft?.purpose, .exerciseSession)
        await coordinator.endWorkout()
        let storedSessions = try await repository.sessions(scope: .all)
        XCTAssertEqual(storedSessions.count, 1)
        await coordinator.toggleDemo()
    }

    func testSignalQualityAgesFromGoodToPoorToDisconnected() {
        let sample: UInt64 = 1_000_000_000
        XCTAssertEqual(HeartRateSignalQualityEvaluator.evaluate(connected: true, reconnecting: false,
                                                                lastSampleNanoseconds: sample, nowNanoseconds: sample + 3_000_000_000), .good)
        XCTAssertEqual(HeartRateSignalQualityEvaluator.evaluate(connected: true, reconnecting: false,
                                                                lastSampleNanoseconds: sample, nowNanoseconds: sample + 3_000_000_001), .poor)
        XCTAssertEqual(HeartRateSignalQualityEvaluator.evaluate(connected: true, reconnecting: false,
                                                                lastSampleNanoseconds: sample, nowNanoseconds: sample + 10_000_000_001), .disconnected)
        XCTAssertEqual(HeartRateSignalQualityEvaluator.evaluate(connected: false, reconnecting: true,
                                                                lastSampleNanoseconds: sample, nowNanoseconds: sample), .poor)
    }

    func testAppearancePresetsRoundTripWithoutLosingAccessibilityChoices() throws {
        for background in SolarBackgroundPreset.allCases {
            for accent in SolarAccentPreset.allCases {
                let original = SolarThemePreferences(background: background, accent: accent, appearance: .system,
                                                     highContrast: true, reducedAnimation: true)
                let decoded = try JSONDecoder().decode(SolarThemePreferences.self,
                                                       from: JSONEncoder().encode(original))
                XCTAssertEqual(decoded, original)
            }
        }
    }

    func testCoachExposesAllObjectivesAndDoesNotInventEvidenceWithoutRealWorkouts() {
        let results = CoachEngine.recommendations(from: [])
        XCTAssertEqual(Set(results.map(\.objective)), Set(CoachingObjective.allCases))
        XCTAssertTrue(results.allSatisfy { !$0.isAvailable })
        XCTAssertTrue(results.allSatisfy { $0.evidence.contains(CoachEngine.algorithmVersion) })
    }
}
