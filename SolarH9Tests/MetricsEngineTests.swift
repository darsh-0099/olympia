import XCTest
@testable import SolarH9

final class MetricsEngineTests: XCTestCase {
    private let fixtureConfiguration = HRVConfiguration(
        algorithmVersion: "test", minimumRRMilliseconds: 300, maximumRRMilliseconds: 2_000,
        localMedianWindow: 5, maximumRelativeDeviation: 0.20,
        minimumAcceptedBeats: 2, minimumDurationSeconds: 0, minimumAcceptedFraction: 0.5
    )

    func testHRVGoldenFixtureUsesSampleSDNNAndStrictPNN50() throws {
        let ticks: [UInt16] = [1_024, 1_126, 1_024, 1_126]
        let samples = ticks.enumerated().map { index, ticks in rr(ticks, index: index) }
        let analysis = try HRVEngine.analyze(samples, context: .restingCheckIn, configuration: fixtureConfiguration)
        XCTAssertEqual(analysis.meanRRMilliseconds.value!, 1_049.804_687_5, accuracy: 0.000_001)
        XCTAssertEqual(analysis.rmssdMilliseconds.value!, 99.609_375, accuracy: 0.000_001)
        XCTAssertEqual(analysis.sdnnMilliseconds.value!, 57.509_499_470_060_376, accuracy: 0.000_001)
        XCTAssertEqual(analysis.pNN50Percent.value, 100)
        XCTAssertEqual(analysis.lnRMSSD.value!, 4.601_256_286_666_955, accuracy: 0.000_001)
    }

    func testHRVDoesNotBridgeExplicitSegments() throws {
        let first = [rr(1_024, index: 0), rr(1_126, index: 1)]
        let second = [rr(819, index: 2), rr(922, index: 3)]
        let result = try HRVEngine.analyze(segments: [first, second], context: .restingCheckIn,
                                           configuration: fixtureConfiguration)
        XCTAssertEqual(result.rmssdMilliseconds.value!, 100.097_656_25, accuracy: 0.6)
    }

    func testRRFilteringPreservesRawValuesAndReasons() throws {
        let samples = [1_024, 1_024, 1, UInt16.max, 1_024].enumerated().map { rr($0.element, index: $0.offset) }
        let originalTicks = samples.map(\.rawTicks1024)
        let result = try HRVEngine.analyze(samples, context: .restingCheckIn, configuration: fixtureConfiguration)
        XCTAssertEqual(samples.map(\.rawTicks1024), originalTicks)
        XCTAssertEqual(result.exclusions.filter { $0.reason == .physiologicBounds }.count, 2)
        XCTAssertEqual(result.acceptedCount, 3)
    }

    func testInsufficientRestingFixtureIsUnavailable() throws {
        let result = try HRVEngine.analyze([rr(1_024, index: 0)], context: .restingCheckIn, configuration: .restingV1)
        XCTAssertEqual(result.rmssdMilliseconds.classification, .unavailable)
        XCTAssertEqual(result.rmssdMilliseconds.quality, .insufficient)
    }

    func testPNN50UsesStrictGreaterThanThresholdAndAllRejectedIsUnavailable() throws {
        let below = try HRVEngine.analyze([rr(1_024, index: 0), rr(1_075, index: 1)],
                                          context: .restingCheckIn, configuration: fixtureConfiguration)
        XCTAssertEqual(below.pNN50Percent.value, 0)
        let above = try HRVEngine.analyze([rr(1_024, index: 0), rr(1_076, index: 1)],
                                          context: .restingCheckIn, configuration: fixtureConfiguration)
        XCTAssertEqual(above.pNN50Percent.value, 100)
        let rejected = try HRVEngine.analyze([rr(1, index: 0), rr(UInt16.max, index: 1)],
                                             context: .restingCheckIn, configuration: fixtureConfiguration)
        XCTAssertEqual(rejected.rmssdMilliseconds.classification, .unavailable)
    }

    func testLocalMedianArtifactBoundaryUsesStrictGreaterThanTwentyPercent() throws {
        let below = try HRVEngine.analyze([rr(1_024, index: 0), rr(1_024, index: 1), rr(1_228, index: 2)],
                                          context: .restingCheckIn, configuration: fixtureConfiguration)
        let above = try HRVEngine.analyze([rr(1_024, index: 0), rr(1_024, index: 1), rr(1_229, index: 2)],
                                          context: .restingCheckIn, configuration: fixtureConfiguration)
        XCTAssertEqual(below.artifactCount, 0)
        XCTAssertEqual(above.artifactCount, 1)
    }

    func testZonesEdwardsLoadAndGapExclusion() throws {
        let zones = HeartRateZoneConfiguration.standard(maximumHeartRate: 200, source: .measured, effectiveAtUTC: Date())
        XCTAssertEqual([99, 100, 120, 140, 160, 180].compactMap(zones.zone), [0, 1, 2, 3, 4, 5])
        let samples = [100, 120, 140, 160, 180].enumerated().map { hr($0.element, second: UInt64($0.offset)) }
        let result = try TrainingLoadEngine.calculate(
            segments: [.init(samples: samples, startMonotonicNanoseconds: 0, endMonotonicNanoseconds: 5_000_000_000)], zones: zones
        )
        XCTAssertEqual(result.edwardsTRIMP.value!, 15 / 60.0, accuracy: 0.000_001)
        let split = try TrainingLoadEngine.calculate(segments: [
            .init(samples: Array(samples.prefix(2)), startMonotonicNanoseconds: 0, endMonotonicNanoseconds: 2_000_000_000),
            .init(samples: Array(samples.dropFirst(2)), startMonotonicNanoseconds: 2_000_000_000, endMonotonicNanoseconds: 5_000_000_000)
        ], zones: zones)
        XCTAssertEqual(split.edwardsTRIMP.value, result.edwardsTRIMP.value)
        let gap = [hr(180, second: 0), hr(180, second: 10)]
        let unavailable = try TrainingLoadEngine.calculate(
            segments: [.init(samples: gap, startMonotonicNanoseconds: 0, endMonotonicNanoseconds: 20_000_000_000)], zones: zones
        )
        XCTAssertEqual(unavailable.edwardsTRIMP.classification, .unavailable)

        let belowZone = (0..<10).map { hr(90, second: UInt64($0)) }
        let zero = try TrainingLoadEngine.calculate(
            segments: [.init(samples: belowZone, startMonotonicNanoseconds: 0, endMonotonicNanoseconds: 10_000_000_000)],
            zones: zones
        )
        XCTAssertEqual(zero.edwardsTRIMP.classification, .calculated)
        XCTAssertEqual(zero.edwardsTRIMP.value, 0)

        let partial = try TrainingLoadEngine.calculate(
            segments: [.init(samples: [hr(180, second: 0), hr(180, second: 1)],
                             startMonotonicNanoseconds: 0, endMonotonicNanoseconds: 10_000_000_000)], zones: zones
        )
        XCTAssertEqual(partial.edwardsTRIMP.classification, .unavailable)
    }

    func testOneMinuteRecoveryRequiresContinuousCoverage() throws {
        let end = Date(timeIntervalSince1970: 1_000)
        let samples = (0...60).map { second in
            HeartRateSampleValue(beatsPerMinute: 170 - (40 * second / 60),
                                 receivedAtUTC: end.addingTimeInterval(Double(second)),
                                 receivedMonotonicNanoseconds: UInt64(second) * 1_000_000_000, origin: .polarH9)
        }
        XCTAssertEqual(try HeartRateRecoveryEngine.oneMinute(samples: samples, exerciseEndedAtUTC: end,
                                                              exerciseEndedMonotonicNanoseconds: 0,
                                                              mode: .standing).detail?.dropBPM, 40)
        XCTAssertEqual(try HeartRateRecoveryEngine.oneMinute(samples: [samples[0], samples[60]],
                                                              exerciseEndedAtUTC: end, exerciseEndedMonotonicNanoseconds: 0,
                                                              mode: .standing).metric.classification,
                       .unavailable)
        let lateCluster = (50...60).flatMap { second in
            (0..<5).map { offset in
                HeartRateSampleValue(beatsPerMinute: 140, receivedAtUTC: end.addingTimeInterval(Double(second)),
                                     receivedMonotonicNanoseconds: UInt64(second) * 1_000_000_000 + UInt64(offset), origin: .polarH9)
            }
        }
        XCTAssertEqual(try HeartRateRecoveryEngine.oneMinute(samples: [samples[0]] + lateCluster,
                                                              exerciseEndedAtUTC: end, exerciseEndedMonotonicNanoseconds: 0,
                                                              mode: .standing).metric.classification,
                       .unavailable)
    }

    func testReadinessBuildsBaselineBeforeScore() throws {
        let today = Date(timeIntervalSince1970: 2_000_000)
        let input = readiness(day: today)
        let short = (1...13).map { readiness(day: today.addingTimeInterval(Double(-$0 * 86_400))) }
        XCTAssertNil(try ReadinessEngine.estimate(today: input, baseline: short).score)
        let enough = short + [readiness(day: today.addingTimeInterval(-14 * 86_400))]
        let estimate = try ReadinessEngine.estimate(today: input, baseline: enough)
        XCTAssertEqual(estimate.score, 50)
        XCTAssertEqual(estimate.metric.classification, .estimated)
        XCTAssertEqual(estimate.metric.lineage.sampleOrigins, [.polarH9])
        XCTAssertEqual(estimate.confidence, .fair)
        XCTAssertNotNil(estimate.evidence)
        let demo = ReadinessInput(dayUTC: today, restingHeartRate: 60, lnRMSSD: 4, origin: .simulator,
                                  purpose: .restingCheckIn, state: .completed, durationSeconds: 240,
                                  interruptionCount: 0, quality: .good)
        XCTAssertNil(try ReadinessEngine.estimate(today: demo, baseline: enough).score)
        let extreme = ReadinessInput(dayUTC: today, restingHeartRate: 20, lnRMSSD: 10, origin: .polarH9,
                                     purpose: .restingCheckIn, state: .completed, durationSeconds: 240,
                                     interruptionCount: 0, quality: .good)
        XCTAssertEqual(try ReadinessEngine.estimate(today: extreme, baseline: enough).score, 98)
        let nonfinite = ReadinessInput(dayUTC: today, restingHeartRate: .nan, lnRMSSD: 4, origin: .polarH9,
                                       purpose: .restingCheckIn, state: .completed, durationSeconds: 240,
                                       interruptionCount: 0, quality: .good)
        XCTAssertNil(try ReadinessEngine.estimate(today: nonfinite, baseline: enough).score)
    }

    private func rr(_ ticks: UInt16, index: Int) -> RRIntervalValue {
        .init(rawTicks1024: ticks, receivedAtUTC: Date(timeIntervalSince1970: Double(index)),
              receivedMonotonicNanoseconds: UInt64(index) * 1_000_000_000,
              derivedBeatTimeUTC: nil, derivedBeatMonotonicNanoseconds: nil, origin: .polarH9)
    }

    private func hr(_ bpm: Int, second: UInt64) -> HeartRateSampleValue {
        .init(beatsPerMinute: bpm, receivedAtUTC: Date(timeIntervalSince1970: Double(second)),
              receivedMonotonicNanoseconds: second * 1_000_000_000, origin: .polarH9)
    }

    private func readiness(day: Date) -> ReadinessInput {
        .init(dayUTC: day, restingHeartRate: 60, lnRMSSD: 4, origin: .polarH9,
              purpose: .restingCheckIn, state: .completed, durationSeconds: 240,
              interruptionCount: 0, quality: .good)
    }
}
