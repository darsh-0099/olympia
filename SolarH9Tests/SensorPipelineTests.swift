import XCTest
@testable import SolarH9

final class SensorPipelineTests: XCTestCase {
    func testParserHandlesEightBitHeartRateWithoutOptionals() throws {
        let parsed = try HeartRateMeasurementParser.parse(Data([0x00, 72]))
        XCTAssertEqual(parsed.beatsPerMinute, 72)
        XCTAssertFalse(parsed.sensorContactSupported)
        XCTAssertNil(parsed.sensorContactDetected)
        XCTAssertNil(parsed.energyExpended)
        XCTAssertTrue(parsed.rrIntervalTicks1024.isEmpty)
    }

    func testParserHandlesEveryFieldAndMultipleRRValues() throws {
        let flags: UInt8 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10
        let parsed = try HeartRateMeasurementParser.parse(
            Data([flags, 0x2C, 0x01, 0x34, 0x12, 0x00, 0x04, 0x80, 0x03])
        )
        XCTAssertEqual(parsed.beatsPerMinute, 300)
        XCTAssertEqual(parsed.sensorContactDetected, true)
        XCTAssertEqual(parsed.energyExpended, 0x1234)
        XCTAssertEqual(parsed.rrIntervalTicks1024, [1_024, 896])
    }

    func testContactDetectedBitIsIgnoredWhenUnsupported() throws {
        let parsed = try HeartRateMeasurementParser.parse(Data([0x02, 60]))
        XCTAssertFalse(parsed.sensorContactSupported)
        XCTAssertNil(parsed.sensorContactDetected)
    }

    func testParserPreservesImplausibleRawRRValues() throws {
        let parsed = try HeartRateMeasurementParser.parse(Data([0x10, 60, 0x01, 0x00, 0xFF, 0xFF]))
        XCTAssertEqual(parsed.rrIntervalTicks1024, [1, UInt16.max])
    }

    func testParserRejectsTruncationAtEveryFieldBoundary() {
        let fixtures: [(Data, HeartRateMeasurementParseError)] = [
            (Data(), .truncated(field: "flags")),
            (Data([0x00]), .truncated(field: "heartRate8")),
            (Data([0x01, 0x2C]), .truncated(field: "heartRate16")),
            (Data([0x08, 60, 0x01]), .truncated(field: "energyExpended")),
            (Data([0x10, 60]), .truncated(field: "rrInterval")),
            (Data([0x10, 60, 0x00]), .truncated(field: "rrInterval"))
        ]
        for (data, expected) in fixtures {
            XCTAssertThrowsError(try HeartRateMeasurementParser.parse(data)) { error in
                XCTAssertEqual(error as? HeartRateMeasurementParseError, expected)
            }
        }
    }

    func testParserAcceptsEveryDefinedFlagCombination() throws {
        for flags in UInt8(0)...UInt8(0x1F) {
            var bytes = [flags]
            if flags & 0x01 != 0 { bytes += [0x2C, 0x01] } else { bytes += [72] }
            if flags & 0x08 != 0 { bytes += [0x34, 0x12] }
            if flags & 0x10 != 0 { bytes += [0x00, 0x04, 0x80, 0x03] }
            let parsed = try HeartRateMeasurementParser.parse(Data(bytes))
            XCTAssertEqual(parsed.rawFlags, flags)
            XCTAssertEqual(parsed.sensorContactSupported, flags & 0x04 != 0)
            XCTAssertEqual(parsed.sensorContactDetected, flags & 0x04 != 0 ? flags & 0x02 != 0 : nil)
        }
    }

    func testPacketPrefixesAcceptOnlyCompleteVariableLengthRRPayloads() throws {
        let full = Data([0x1F, 0x2C, 0x01, 0x34, 0x12, 0x00, 0x04, 0x80, 0x03])
        XCTAssertNoThrow(try HeartRateMeasurementParser.parse(full))
        for length in 0..<full.count {
            if length == 7 {
                let parsed = try HeartRateMeasurementParser.parse(full.prefix(length))
                XCTAssertEqual(parsed.rrIntervalTicks1024, [1_024])
            } else {
                XCTAssertThrowsError(try HeartRateMeasurementParser.parse(full.prefix(length)), "prefix length \(length)")
            }
        }
    }

    func testEveryRFUBitIsRejected() {
        for bit: UInt8 in [0x20, 0x40, 0x80] {
            XCTAssertThrowsError(try HeartRateMeasurementParser.parse(Data([bit, 60]))) { error in
                XCTAssertEqual(error as? HeartRateMeasurementParseError, .reservedFlagsSet(bit))
            }
        }
    }

    func testParserRejectsRFUFlagsAndUnexpectedTrailingData() {
        XCTAssertThrowsError(try HeartRateMeasurementParser.parse(Data([0x20, 60]))) { error in
            XCTAssertEqual(error as? HeartRateMeasurementParseError, .reservedFlagsSet(0x20))
        }
        XCTAssertThrowsError(try HeartRateMeasurementParser.parse(Data([0x00, 60, 0x00]))) { error in
            XCTAssertEqual(error as? HeartRateMeasurementParseError, .trailingByte)
        }
    }

    func testMultipleRRTimestampsRemainOldestToNewest() throws {
        let parsed = try HeartRateMeasurementParser.parse(Data([0x10, 60, 0x00, 0x04, 0x00, 0x02]))
        let received = Date(timeIntervalSince1970: 10_000)
        let samples = HeartRateMeasurementTimestamping.rrSamples(
            from: parsed,
            receivedAtUTC: received,
            monotonicNanoseconds: 2_000_000_000,
            origin: .polarH9
        )

        XCTAssertEqual(samples.map(\.rawTicks1024), [1_024, 512])
        XCTAssertEqual(samples[0].derivedBeatTimeUTC, received.addingTimeInterval(-0.5))
        XCTAssertEqual(samples[1].derivedBeatTimeUTC, received)
        XCTAssertEqual(samples.map(\.receivedMonotonicNanoseconds), [2_000_000_000, 2_000_000_000])
        XCTAssertLessThan(
            try XCTUnwrap(samples[0].derivedBeatMonotonicNanoseconds),
            try XCTUnwrap(samples[1].derivedBeatMonotonicNanoseconds)
        )
        XCTAssertEqual(samples.map(\.receivedAtUTC), [received, received])
    }

    func testConnectionReducerRequiresSubscriptionBeforeConnected() {
        let id = UUID()
        var machine = SensorConnectionMachine()
        machine.handle(.availabilityChanged(.poweredOn))
        machine.handle(.connectRequested(id))
        machine.handle(.transportConnected(id))
        XCTAssertEqual(machine.state, .connecting(id))
        machine.handle(.subscriptionReady(id))
        XCTAssertEqual(machine.state, .connected(id))
    }

    func testConnectionReducerBoundsBackoffAndIgnoresStaleCallbacks() {
        let selected = UUID()
        let stale = UUID()
        let policy = RetryPolicy(maximumAttempts: 2, initialDelaySeconds: 1, maximumDelaySeconds: 2)
        var machine = SensorConnectionMachine(retryPolicy: policy)
        machine.handle(.connectRequested(selected))
        machine.handle(.transportDisconnected(stale, shouldRetry: true))
        XCTAssertEqual(machine.state, .connecting(selected))

        machine.handle(.timeout(selected))
        XCTAssertEqual(machine.state, .reconnecting(selected, attempt: 1))
        XCTAssertEqual(machine.retryPolicy.delay(forAttempt: 1), 1)
        machine.handle(.retryFired(selected))
        machine.handle(.timeout(selected))
        XCTAssertEqual(machine.state, .reconnecting(selected, attempt: 2))
        XCTAssertEqual(machine.retryPolicy.delay(forAttempt: 2), 2)
        machine.handle(.retryFired(selected))
        machine.handle(.timeout(selected))
        guard case .error = machine.state else { return XCTFail("Expected exhausted retry error") }
    }

    func testUserDisconnectAndForgetCancelReconnectState() {
        let id = UUID()
        var machine = SensorConnectionMachine()
        machine.handle(.connectRequested(id))
        machine.handle(.timeout(id))
        machine.handle(.userDisconnected)
        XCTAssertEqual(machine.state, .disconnected)
        machine.handle(.transportConnected(id))
        machine.handle(.subscriptionReady(id))
        machine.handle(.timeout(id))
        XCTAssertEqual(machine.state, .disconnected)
        XCTAssertEqual(machine.selectedDeviceID, id)
        machine.handle(.forgotDevice)
        XCTAssertNil(machine.selectedDeviceID)
    }

    func testSimulatorIsDeterministicAndPatternsStayDistinct() {
        for pattern in SimulationPattern.allCases {
            var first = SimulatedSequenceGenerator(pattern: pattern, seed: 42)
            var second = SimulatedSequenceGenerator(pattern: pattern, seed: 42)
            let firstFrames = (0..<80).map { _ in first.nextFrame() }
            let secondFrames = (0..<80).map { _ in second.nextFrame() }
            XCTAssertEqual(firstFrames, secondFrames)
        }

        var noisy = SimulatedSequenceGenerator(pattern: .noisyArtifacts, seed: 1)
        let noisyFrames = (0..<30).map { _ in noisy.nextFrame() }
        XCTAssertTrue(noisyFrames.contains { $0.rrMilliseconds < 300 || $0.rrMilliseconds > 2_000 })

        var disconnecting = SimulatedSequenceGenerator(pattern: .disconnectReconnect, seed: 1)
        let disconnectFrames = (0..<40).map { _ in disconnecting.nextFrame() }
        XCTAssertTrue(disconnectFrames.contains(where: \.startsInterruption))
        XCTAssertTrue(disconnectFrames.contains(where: \.endsInterruption))

        func bpmSeries(_ pattern: SimulationPattern) -> [Int] {
            var generator = SimulatedSequenceGenerator(pattern: pattern, seed: 7)
            return (0..<24).map { _ in generator.nextFrame().beatsPerMinute }
        }
        XCTAssertNotEqual(bpmSeries(.resting), bpmSeries(.intervals))
        XCTAssertNotEqual(bpmSeries(.intervals), bpmSeries(.gradualRamp))
        XCTAssertNotEqual(bpmSeries(.gradualRamp), bpmSeries(.noisyArtifacts))
    }

    func testSavedFixtureIsReplayedExactlyIncludingControlMarkers() {
        let fixture = [
            SimulatedFrame(beatsPerMinute: 50, rrMilliseconds: 1_200, startsInterruption: false, endsInterruption: false),
            SimulatedFrame(beatsPerMinute: 0, rrMilliseconds: 0, startsInterruption: true, endsInterruption: false),
            SimulatedFrame(beatsPerMinute: 0, rrMilliseconds: 0, startsInterruption: false, endsInterruption: true)
        ]
        var generator = SimulatedSequenceGenerator(pattern: .savedFixture, seed: 999, savedFixture: fixture)
        XCTAssertEqual((0..<6).map { _ in generator.nextFrame() }, fixture + fixture)
    }

    func testDerivedBeatMonotonicTimeIsNilRatherThanClampedOnUnderflow() throws {
        let parsed = try HeartRateMeasurementParser.parse(Data([0x10, 60, 0x00, 0x04, 0x00, 0x04]))
        let samples = HeartRateMeasurementTimestamping.rrSamples(
            from: parsed, receivedAtUTC: Date(), monotonicNanoseconds: 100, origin: .polarH9
        )
        XCTAssertNil(samples[0].derivedBeatMonotonicNanoseconds)
        XCTAssertEqual(samples[0].receivedMonotonicNanoseconds, 100)
        XCTAssertEqual(samples[1].receivedMonotonicNanoseconds, 100)
    }

    func testSimulatorEventsAreExplicitlySimulatorOrigin() async throws {
        let source = SimulatedHeartRateSource(pattern: .resting, playbackRate: 1_000)
        let stream = await source.eventStream()
        try await source.start()
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        await source.stop()
        guard case .heartRate(let sample) = event else { return XCTFail("Expected first simulated heart-rate event") }
        XCTAssertEqual(sample.origin, .simulator)
    }

    func testSimulatorSurfacesBoundedBufferOverflowAsDataLoss() async throws {
        let source = SimulatedHeartRateSource(pattern: .resting, playbackRate: 10_000, eventBufferLimit: 1)
        let stream = await source.eventStream()
        try await source.start()
        try await Task.sleep(for: .milliseconds(20))
        await source.stop()
        var iterator = stream.makeAsyncIterator()
        guard let event = await iterator.next() else { return XCTFail("Expected buffered event") }
        guard case .dataLoss = event else { return XCTFail("Expected explicit data-loss marker after overflow") }
    }

    func testSavedFixtureSourcePreservesOrderAndPairsGapMarkers() async throws {
        let fixture = [
            SimulatedFrame(beatsPerMinute: 55, rrMilliseconds: 1_091, startsInterruption: false, endsInterruption: false),
            SimulatedFrame(beatsPerMinute: 0, rrMilliseconds: 0, startsInterruption: true, endsInterruption: false),
            SimulatedFrame(beatsPerMinute: 0, rrMilliseconds: 0, startsInterruption: false, endsInterruption: true)
        ]
        let source = SimulatedHeartRateSource(pattern: .savedFixture, playbackRate: 10_000, savedFixture: fixture)
        let stream = await source.eventStream()
        var iterator = stream.makeAsyncIterator()
        try await source.start()
        let events = [await iterator.next(), await iterator.next(), await iterator.next(), await iterator.next()].compactMap { $0 }
        await source.stop()
        guard events.count == 4,
              case .heartRate(let heartRate) = events[0],
              case .rrIntervals(let intervals) = events[1],
              case .interruptionStarted(let startedID, _, _) = events[2],
              case .interruptionEnded(let endedID, _) = events[3] else {
            return XCTFail("Expected HR, RR, gap start, and matching gap end")
        }
        XCTAssertEqual(heartRate.beatsPerMinute, 55)
        XCTAssertEqual(intervals.first?.origin, .simulator)
        XCTAssertEqual(startedID, endedID)
    }

    func testSimulatorRapidRestartDoesNotLeaveAStaleProducer() async throws {
        let fixture = [51, 52, 53].map {
            SimulatedFrame(beatsPerMinute: $0, rrMilliseconds: 60_000 / Double($0),
                           startsInterruption: false, endsInterruption: false)
        }
        let source = SimulatedHeartRateSource(pattern: .savedFixture, playbackRate: 1, savedFixture: fixture)
        let stream = await source.eventStream()
        var iterator = stream.makeAsyncIterator()
        try await source.start()
        _ = await iterator.next()
        _ = await iterator.next()
        var counts = await source.producerCountsForTesting()
        XCTAssertEqual(counts.active, 1)
        await source.stop()
        counts = await source.producerCountsForTesting()
        XCTAssertEqual(counts.active, 0)
        try await source.start()
        counts = await source.producerCountsForTesting()
        XCTAssertEqual(counts.active, 1)
        let restarted = [await iterator.next(), await iterator.next(), await iterator.next(), await iterator.next()].compactMap { $0 }
        await source.stop()
        counts = await source.producerCountsForTesting()
        XCTAssertEqual(counts.maximum, 1)
        let heartRates = restarted.compactMap { event -> Int? in
            guard case .heartRate(let sample) = event else { return nil }
            return sample.beatsPerMinute
        }
        XCTAssertEqual(heartRates, [52, 53])
    }

    func testSimulatorSerializesConcurrentStopAndRestart() async throws {
        let barrier = BlockingSimulatorStopBarrier()
        let source = SimulatedHeartRateSource(pattern: .resting, playbackRate: 1, stopBarrier: barrier)
        try await source.start()
        async let stopping: Void = source.stop()
        await barrier.waitUntilEntered()
        async let restarting: Void = source.start()
        await barrier.waitUntilRestartObserved()
        await barrier.release()
        _ = try await (stopping, restarting)
        let counts = await source.producerCountsForTesting()
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.maximum, 1)
        await source.stop()
    }
}

private actor BlockingSimulatorStopBarrier: SimulatorStopBarrier {
    private var entered = false
    private var released = false
    private var restartWasObserved = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var restartWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func restartObserved() async {
        restartWasObserved = true
        restartWaiters.forEach { $0.resume() }
        restartWaiters.removeAll()
    }

    func waitUntilRestartObserved() async {
        guard !restartWasObserved else { return }
        await withCheckedContinuation { restartWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
