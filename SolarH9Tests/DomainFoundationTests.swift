import XCTest
@testable import SolarH9

final class DomainFoundationTests: XCTestCase {
    func testLiveActivityStateRoundTripsWithoutLosingHeartRateContext() throws {
        let state = HeartRateActivityAttributes.ContentState(
            beatsPerMinute: 147,
            averageBeatsPerMinute: 139,
            phase: .recording,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pulse: true,
            zone: 3,
            targetZone: 3,
            connectionQuality: .good
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(HeartRateActivityAttributes.ContentState.self, from: encoded)

        XCTAssertEqual(decoded, state)
    }

    func testLiveActivityStateDecodesPreviousVersionWithoutZoneQualityOrMotionFields() throws {
        let json = #"{"beatsPerMinute":147,"averageBeatsPerMinute":139,"phase":"recording","updatedAt":721692800,"pulse":true}"#
        let decoded = try JSONDecoder().decode(HeartRateActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.beatsPerMinute, 147)
        XCTAssertNil(decoded.zone)
        XCTAssertEqual(decoded.connectionQuality, .poor)
        XCTAssertFalse(decoded.reduceMotion)
    }

    func testLiveActivityAttributesDecodePreviousSessionKeysAsWorkout() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let json = #"{"sessionID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","startedAt":721692800,"purpose":"Workout","isSimulated":false}"#
        let decoded = try JSONDecoder().decode(HeartRateActivityAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activityID, id)
        XCTAssertEqual(decoded.mode, .workout)
    }

    func testRRTicksConvertWithoutIntegerTruncation() {
        let sample = RRIntervalValue(
            rawTicks1024: 853,
            receivedAtUTC: Date(timeIntervalSince1970: 1_700_000_000),
            receivedMonotonicNanoseconds: 42,
            derivedBeatTimeUTC: nil,
            derivedBeatMonotonicNanoseconds: nil,
            origin: .polarH9
        )

        XCTAssertEqual(sample.milliseconds, 833.0078125, accuracy: 0.000_000_1)
        XCTAssertEqual(sample.rawTicks1024, 853)
    }

    func testRestingContextPrecheckDoesNotClaimFullQualityEligibility() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let eligible = try SessionDraft(
            purpose: .restingCheckIn,
            origin: .polarH9,
            startedAtUTC: date,
            endedAtUTC: date.addingTimeInterval(240),
            state: .completed
        )
        let demo = try SessionDraft(
            purpose: .restingCheckIn,
            origin: .simulator,
            startedAtUTC: date,
            endedAtUTC: date.addingTimeInterval(240),
            state: .completed
        )
        let exercise = try SessionDraft(
            purpose: .exerciseSession,
            origin: .polarH9,
            startedAtUTC: date,
            endedAtUTC: date.addingTimeInterval(240),
            state: .completed
        )
        let interrupted = try SessionDraft(
            purpose: .restingCheckIn,
            origin: .polarH9,
            startedAtUTC: date,
            endedAtUTC: date.addingTimeInterval(240),
            state: .completed,
            interruptions: [InterruptionMarker(startedAtUTC: date, endedAtUTC: date.addingTimeInterval(5), reason: "test")]
        )

        XCTAssertTrue(eligible.passesRestingContextPrecheck)
        XCTAssertFalse(demo.passesRestingContextPrecheck)
        XCTAssertFalse(exercise.passesRestingContextPrecheck)
        XCTAssertFalse(interrupted.passesRestingContextPrecheck)
    }

    func testUnavailableMetricCarriesReasonWithoutValue() throws {
        let result = try MetricResult(
            id: "readiness",
            name: "Solar Readiness",
            value: nil,
            unit: "score",
            classification: .unavailable,
            context: .restingCheckIn,
            lineage: MetricLineage(sampleOrigins: [.polarH9], includesUserInput: true),
            algorithmVersion: "readiness-v1",
            configurationVersion: "readiness-config-v1",
            quality: .insufficient,
            reasons: ["Seven valid check-ins are required before a score is estimated."]
        )

        XCTAssertNil(result.value)
        XCTAssertEqual(result.classification, .unavailable)
        XCTAssertEqual(result.quality, .insufficient)
        XCTAssertFalse(result.reasons.isEmpty)
    }

    func testMetricDecoderRejectsUnavailableValue() throws {
        let invalid = """
        {
          "id":"readiness","name":"Solar Readiness","value":81,"unit":"score",
          "classification":"unavailable","context":"restingCheckIn",
          "lineage":{"sampleOrigins":["polarH9"],"includesUserInput":false},
          "algorithmVersion":"readiness-v1","configurationVersion":"readiness-config-v1",
          "quality":"insufficient","reasons":["Baseline building"]
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(MetricResult.self, from: Data(invalid.utf8)))
    }

    func testMetricInitializerRejectsMissingReasonAndNonFiniteValue() {
        XCTAssertThrowsError(
            try MetricResult(
                id: "readiness",
                name: "Solar Readiness",
                value: nil,
                unit: "score",
                classification: .unavailable,
                context: .restingCheckIn,
                lineage: MetricLineage(sampleOrigins: [.polarH9]),
                algorithmVersion: "readiness-v1",
                configurationVersion: "readiness-config-v1",
                quality: .insufficient,
                reasons: []
            )
        ) { error in
            XCTAssertEqual(error as? MetricResultValidationError, .missingReason)
        }

        XCTAssertThrowsError(
            try MetricResult(
                id: "rmssd",
                name: "RMSSD",
                value: .infinity,
                unit: "ms",
                classification: .calculated,
                context: .restingCheckIn,
                lineage: MetricLineage(sampleOrigins: [.polarH9]),
                algorithmVersion: "hrv-v1",
                configurationVersion: "hrv-config-v1",
                quality: .good,
                reasons: []
            )
        ) { error in
            XCTAssertEqual(error as? MetricResultValidationError, .nonFiniteValue)
        }

        XCTAssertThrowsError(
            try MetricResult(
                id: "rmssd",
                name: "RMSSD",
                value: 42,
                unit: "ms",
                classification: .calculated,
                context: .restingCheckIn,
                lineage: MetricLineage(sampleOrigins: []),
                algorithmVersion: "hrv-v1",
                configurationVersion: "hrv-config-v1",
                quality: .good,
                reasons: []
            )
        ) { error in
            XCTAssertEqual(error as? MetricResultValidationError, .missingLineage)
        }

        XCTAssertThrowsError(
            try MetricResult(
                id: "rmssd",
                name: "RMSSD",
                value: 42,
                unit: "ms",
                classification: .calculated,
                context: .restingCheckIn,
                lineage: MetricLineage(sampleOrigins: [.polarH9]),
                algorithmVersion: " ",
                configurationVersion: "hrv-config-v1",
                quality: .good,
                reasons: []
            )
        ) { error in
            XCTAssertEqual(error as? MetricResultValidationError, .missingVersion)
        }
    }

    func testSessionRejectsMixedSampleOriginsAtConstructionAppendAndDecode() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let simulated = HeartRateSampleValue(
            beatsPerMinute: 60,
            receivedAtUTC: date,
            receivedMonotonicNanoseconds: 1,
            origin: .simulator
        )

        XCTAssertThrowsError(
            try SessionDraft(
                purpose: .restingCheckIn,
                origin: .polarH9,
                startedAtUTC: date,
                heartRates: [simulated]
            )
        )

        var real = try SessionDraft(
            purpose: .exerciseSession,
            origin: .polarH9,
            startedAtUTC: date
        )
        XCTAssertThrowsError(try real.append(simulated)) { error in
            XCTAssertEqual(error as? SessionDraftError, .sampleOriginMismatch)
        }
        XCTAssertTrue(real.heartRates.isEmpty)

        let simulatedRR = RRIntervalValue(
            rawTicks1024: 1_024,
            receivedAtUTC: date,
            receivedMonotonicNanoseconds: 2,
            derivedBeatTimeUTC: nil,
            derivedBeatMonotonicNanoseconds: nil,
            origin: .simulator
        )
        XCTAssertThrowsError(try real.append(simulatedRR)) { error in
            XCTAssertEqual(error as? SessionDraftError, .sampleOriginMismatch)
        }
        XCTAssertTrue(real.rrIntervals.isEmpty)

        let realSample = HeartRateSampleValue(
            beatsPerMinute: 60,
            receivedAtUTC: date,
            receivedMonotonicNanoseconds: 1,
            origin: .polarH9
        )
        try real.append(realSample)
        let encoded = try JSONEncoder().encode(real)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var heartRates = try XCTUnwrap(json["heartRates"] as? [[String: Any]])
        heartRates[0]["origin"] = SampleOrigin.simulator.rawValue
        json["heartRates"] = heartRates
        let corrupted = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionDraft.self, from: corrupted)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testRRBoundariesRoundTrip() throws {
        for ticks in [UInt16.min, 1, 1_023, 1_024, UInt16.max] {
            let sample = RRIntervalValue(
                rawTicks1024: ticks,
                receivedAtUTC: Date(timeIntervalSince1970: 1_700_000_000),
                receivedMonotonicNanoseconds: UInt64(ticks),
                derivedBeatTimeUTC: nil,
                derivedBeatMonotonicNanoseconds: nil,
                origin: .polarH9
            )
            let decoded = try JSONDecoder().decode(RRIntervalValue.self, from: JSONEncoder().encode(sample))
            XCTAssertEqual(decoded, sample)
            XCTAssertEqual(decoded.milliseconds, Double(ticks) * 1_000 / 1_024, accuracy: 0.000_000_1)
        }
    }

    func testSessionLifecycleRequiresConsistentEndState() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(
            try SessionDraft(
                purpose: .exerciseSession,
                origin: .polarH9,
                startedAtUTC: date,
                state: .completed
            )
        ) { error in
            XCTAssertEqual(error as? SessionDraftError, .invalidLifecycle)
        }
        XCTAssertThrowsError(
            try SessionDraft(
                purpose: .exerciseSession,
                origin: .polarH9,
                startedAtUTC: date,
                endedAtUTC: date.addingTimeInterval(30),
                state: .recording
            )
        ) { error in
            XCTAssertEqual(error as? SessionDraftError, .invalidLifecycle)
        }

        let openMarker = InterruptionMarker(startedAtUTC: date, endedAtUTC: nil, reason: "connection lost")
        XCTAssertThrowsError(
            try SessionDraft(
                purpose: .exerciseSession,
                origin: .polarH9,
                startedAtUTC: date,
                endedAtUTC: date.addingTimeInterval(30),
                state: .interrupted,
                interruptions: [openMarker]
            )
        ) { error in
            XCTAssertEqual(error as? SessionDraftError, .invalidLifecycle)
        }
    }

    func testTerminalSessionRejectsLateCallbacks() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var completed = try SessionDraft(
            purpose: .exerciseSession,
            origin: .polarH9,
            startedAtUTC: date,
            endedAtUTC: date.addingTimeInterval(60),
            state: .completed
        )
        let heartRate = HeartRateSampleValue(
            beatsPerMinute: 100,
            receivedAtUTC: date.addingTimeInterval(61),
            receivedMonotonicNanoseconds: 1,
            origin: .polarH9
        )
        let rr = RRIntervalValue(
            rawTicks1024: 700,
            receivedAtUTC: date.addingTimeInterval(61),
            receivedMonotonicNanoseconds: 2,
            derivedBeatTimeUTC: nil,
            derivedBeatMonotonicNanoseconds: nil,
            origin: .polarH9
        )
        let marker = InterruptionMarker(
            startedAtUTC: date.addingTimeInterval(61),
            endedAtUTC: date.addingTimeInterval(62),
            reason: "late callback"
        )

        XCTAssertThrowsError(try completed.append(heartRate))
        XCTAssertThrowsError(try completed.append(rr))
        XCTAssertThrowsError(try completed.beginInterruption(id: marker.id, at: marker.startedAtUTC, reason: marker.reason))
        XCTAssertTrue(completed.heartRates.isEmpty)
        XCTAssertTrue(completed.rrIntervals.isEmpty)
        XCTAssertTrue(completed.interruptions.isEmpty)
    }

    func testInterruptionMustCloseBeforeCompletionAndRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let interruptionID = UUID()
        var session = try SessionDraft(
            purpose: .exerciseSession,
            origin: .polarH9,
            startedAtUTC: date
        )

        try session.beginInterruption(id: interruptionID, at: date.addingTimeInterval(10), reason: "connection lost")
        XCTAssertThrowsError(try session.complete(at: date.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? SessionDraftError, .invalidLifecycle)
        }

        try session.endInterruption(id: interruptionID, at: date.addingTimeInterval(20))
        try session.complete(at: date.addingTimeInterval(60))
        let decoded = try JSONDecoder().decode(SessionDraft.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
    }

    func testMarkInterruptedRejectsOpenOrOutOfRangeMarker() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let open = InterruptionMarker(startedAtUTC: date.addingTimeInterval(10), endedAtUTC: nil, reason: "connection lost")
        var session = try SessionDraft(
            purpose: .exerciseSession,
            origin: .polarH9,
            startedAtUTC: date
        )
        XCTAssertThrowsError(try session.markInterrupted(at: date.addingTimeInterval(60), marker: open))
        XCTAssertEqual(session.state, .recording)
        XCTAssertTrue(session.interruptions.isEmpty)
    }

    func testUnavailableMetricMayHaveNoObservedInputButMixedInputIsRejected() throws {
        let noInput = try MetricResult(
            id: "resting-hr",
            name: "Resting HR",
            value: nil,
            unit: "bpm",
            classification: .unavailable,
            context: .restingCheckIn,
            lineage: MetricLineage(sampleOrigins: []),
            algorithmVersion: "measurement-v1",
            configurationVersion: "measurement-config-v1",
            quality: .insufficient,
            reasons: ["No compatible sensor sample has been recorded."]
        )
        XCTAssertTrue(noInput.lineage.sampleOrigins.isEmpty)

        XCTAssertThrowsError(
            try MetricResult(
                id: "rmssd",
                name: "RMSSD",
                value: 42,
                unit: "ms",
                classification: .calculated,
                context: .restingCheckIn,
                lineage: MetricLineage(sampleOrigins: [.polarH9, .simulator]),
                algorithmVersion: "hrv-v1",
                configurationVersion: "hrv-config-v1",
                quality: .good,
                reasons: []
            )
        ) { error in
            XCTAssertEqual(error as? MetricResultValidationError, .mixedRealAndSimulatedLineage)
        }
    }

    @MainActor
    func testDemoSelectionPersistsAcrossRelaunch() {
        let suite = "tests.app-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = AppModel(defaults: defaults)
        initial.completeOnboarding(useDemoMode: true)
        let relaunched = AppModel(defaults: defaults)

        XCTAssertTrue(relaunched.hasCompletedOnboarding)
        XCTAssertTrue(relaunched.isDemoModeEnabled)
        XCTAssertEqual(initial.selectedTab, .live)
    }

    func testInjectedClockIsDeterministic() {
        struct TestClock: SolarClock {
            let date: Date
            let ticks: UInt64
            func nowUTC() -> Date { date }
            func monotonicNanoseconds() -> UInt64 { ticks }
        }

        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(date: expected, ticks: 99)
        XCTAssertEqual(clock.nowUTC(), expected)
        XCTAssertEqual(clock.monotonicNanoseconds(), 99)
    }
}
