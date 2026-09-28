import XCTest
@testable import SolarH9

@MainActor
final class ExperienceTests: XCTestCase {
    func testConsecutiveWorkoutsUseDistinctRecordingsAndDiscardPreservesPrevious() async throws {
        let defaults = UserDefaults(suiteName: "test.workout.lifecycle.\(UUID().uuidString)")!
        let repository = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(inMemory: true))
        let recording = RecordingController(repository: repository)
        let coordinator = SensorCoordinator(sensor: PolarH9Client(defaults: defaults), recording: recording)
        await coordinator.select(.simulator)

        let firstResult = await coordinator.startWorkout()
        let firstID = try XCTUnwrap(firstResult)
        let firstEnded = await coordinator.endWorkout(id: firstID)
        XCTAssertTrue(firstEnded)
        let secondResult = await coordinator.startWorkout()
        let secondID = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(coordinator.hasActiveRecording)
        XCTAssertEqual(recording.draft?.id, secondID)

        let secondEnded = await coordinator.endWorkout(id: secondID)
        XCTAssertTrue(secondEnded)
        try await repository.deleteSession(id: secondID)
        let saved = try await repository.sessions(scope: .all)
        XCTAssertEqual(saved.map(\.id), [firstID])
    }

    func testWorkoutStartDoesNotAdoptAnExistingRecordingAndScopedEndLeavesItActive() async throws {
        let defaults = UserDefaults(suiteName: "test.workout.identity.\(UUID().uuidString)")!
        let repository = SwiftDataSessionRepository(container: try SolarPersistence.makeContainer(inMemory: true))
        let recording = RecordingController(repository: repository)
        let coordinator = SensorCoordinator(sensor: PolarH9Client(defaults: defaults), recording: recording)
        await coordinator.select(.simulator)
        let activeResult = await coordinator.startWorkout()
        let activeID = try XCTUnwrap(activeResult)

        let duplicateResult = await coordinator.startWorkout()
        XCTAssertNil(duplicateResult)
        let unrelatedEnded = await coordinator.endWorkout(id: UUID())
        XCTAssertTrue(unrelatedEnded)
        XCTAssertTrue(coordinator.hasActiveRecording)
        XCTAssertEqual(recording.draft?.id, activeID)

        await coordinator.pauseOrResume(id: UUID())
        XCTAssertEqual(recording.status, .recording(activeID))
        await coordinator.pauseOrResume(id: activeID)
        XCTAssertEqual(recording.status, .paused(activeID))
        await coordinator.pauseOrResume(id: UUID())
        XCTAssertEqual(recording.status, .paused(activeID))
        await coordinator.pauseOrResume(id: activeID)
        XCTAssertEqual(recording.status, .recording(activeID))

        // Cleanup does not require a view-local "started" flag or a ready
        // sensor: a restored paused workout only needs its persisted ID.
        await coordinator.pauseOrResume()
        XCTAssertEqual(recording.status, .paused(activeID))
        let ended = await coordinator.endWorkout(id: activeID)
        XCTAssertTrue(ended)
        XCTAssertFalse(coordinator.hasActiveRecording)
    }

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

    func testNoteImportPreservesRepGroupsAndKnownCableCurlAlias() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        let report = OlympiaNoteImporter.importWorkouts("""
        Pull 9/2/25:
        1. Cable Straight Bar Bicep Curl - 4 sets - 12/12/11.5/10 reps - 37.5lbs
        Pull 3/20/26:
        1. Cable Straight Bar Curl (Smith bar under armpits) - 8/7 (20kg), 9 (30lbs)
        """, into: store)

        XCTAssertEqual(report.sessions, 2)
        XCTAssertEqual(report.sets, 7)
        let latest = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(latest.completedSets.compactMap(\.reps), [8, 7, 9])
        let weights = latest.completedSets.compactMap(\.weightPounds)
        XCTAssertEqual(weights.count, 3)
        XCTAssertEqual(weights[0], 20 * 2.2046226218, accuracy: 0.001)
        XCTAssertEqual(weights[1], 20 * 2.2046226218, accuracy: 0.001)
        XCTAssertEqual(weights[2], 30, accuracy: 0.001)
        XCTAssertEqual(olympiaExerciseKey("Cable Straight Bar Bicep Curl"),
                       olympiaExerciseKey("Cable Straight Bar Curl (Smith bar under armpits)"))
        XCTAssertEqual(store.historyExercises().count, 1)
        XCTAssertEqual(store.historyWorkoutSuggestions().first?.exercises.first?.sets, 3)
        let early = try XCTUnwrap(store.sessions.last)
        XCTAssertEqual(early.completedSets[2].reps, 12)
        XCTAssertEqual(early.completedSets[2].preciseReps, 11.5)
        XCTAssertEqual(early.completedSets[2].effectiveReps, 11.5)
        XCTAssertEqual(early.completedSets[2].displayReps, "11.5")

        let encoded = try JSONEncoder().encode(early.completedSets[2])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "preciseReps")
        let legacySet = try JSONDecoder().decode(OlympiaCompletedSet.self,
                                                 from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacySet.preciseReps)
        XCTAssertEqual(legacySet.effectiveReps, 12)
    }

    func testHistoryWorkoutSuggestionsKeepsDistinctRoutinesWithSameName() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        _ = OlympiaNoteImporter.importWorkouts("""
        Pull 3/20/26:
        1. Cable Row - 3 sets - 12 reps - 60lbs
        Pull 3/21/26:
        1. Lat Pulldown - 3 sets - 10 reps - 70lbs
        """, into: store)

        XCTAssertEqual(store.historyWorkoutSuggestions().count, 2)
    }

    func testNoteImportDoesNotTreatDateLookingSlashRepsAsAHeader() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        let report = OlympiaNoteImporter.importWorkouts("""
        Push 7/28/25:
        1. Bench Press - 12/10/10 - 85lbs
        """, into: store)
        XCTAssertEqual(report.sessions, 1)
        XCTAssertEqual(report.sets, 3)
        XCTAssertEqual(store.sessions.count, 1)
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.name, "Push")
        XCTAssertEqual(session.completedSets.compactMap(\.reps), [12, 10, 10])
    }

    func testInvalidWorkoutDatesDoNotCreateSessionsOrLeakSetsIntoPriorWorkout() throws {
        let store = try OlympiaTrainingStore(inMemory: true)
        let report = OlympiaNoteImporter.importWorkouts("""
        Push 7/28/25:
        1. Bench Press - 12/10/10 - 85lbs
        Invalid February 2/30/25:
        1. Squat - 8/8/8 - 135lbs
        Invalid Month 13/1/25:
        1. Deadlift - 5/5/5 - 185lbs
        Pull 7/29/25:
        1. Row - 10/10/10 - 65lbs
        """, into: store)
        XCTAssertEqual(report.sessions, 2)
        XCTAssertEqual(report.sets, 6)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(Set(store.sessions.map(\.name)), ["Push", "Pull"])
        let push = try XCTUnwrap(store.sessions.first { $0.name == "Push" })
        let pull = try XCTUnwrap(store.sessions.first { $0.name == "Pull" })
        XCTAssertEqual(push.completedSets.map(\.exerciseName), Array(repeating: "Bench Press", count: 3))
        XCTAssertEqual(pull.completedSets.map(\.exerciseName), Array(repeating: "Row", count: 3))
        XCTAssertEqual(push.completedSets.compactMap(\.reps), [12, 10, 10])
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
