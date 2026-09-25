import Foundation

enum SimulationPattern: String, CaseIterable, Codable, Sendable {
    case resting
    case intervals
    case gradualRamp
    case noisyArtifacts
    case disconnectReconnect
    case savedFixture
}

struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

struct SimulatedFrame: Equatable, Sendable {
    let beatsPerMinute: Int
    let rrMilliseconds: Double
    let startsInterruption: Bool
    let endsInterruption: Bool
}

struct SimulatedSequenceGenerator: Sendable {
    let pattern: SimulationPattern
    private let savedFixture: [SimulatedFrame]
    private var random: SeededRandomNumberGenerator
    private(set) var index = 0

    init(pattern: SimulationPattern, seed: UInt64, savedFixture: [SimulatedFrame] = Self.defaultFixture) {
        self.pattern = pattern
        self.savedFixture = savedFixture.isEmpty ? Self.defaultFixture : savedFixture
        random = SeededRandomNumberGenerator(seed: seed)
    }

    static let defaultFixture = [
        SimulatedFrame(beatsPerMinute: 62, rrMilliseconds: 967.0, startsInterruption: false, endsInterruption: false),
        SimulatedFrame(beatsPerMinute: 64, rrMilliseconds: 938.0, startsInterruption: false, endsInterruption: false),
        SimulatedFrame(beatsPerMinute: 0, rrMilliseconds: 0, startsInterruption: true, endsInterruption: false),
        SimulatedFrame(beatsPerMinute: 0, rrMilliseconds: 0, startsInterruption: false, endsInterruption: true),
        SimulatedFrame(beatsPerMinute: 66, rrMilliseconds: 909.0, startsInterruption: false, endsInterruption: false)
    ]

    mutating func nextFrame() -> SimulatedFrame {
        defer { index += 1 }
        let randomNoise = Int((random.unit() * 5).rounded()) - 2
        if pattern == .savedFixture { return savedFixture[index % savedFixture.count] }
        let noise = randomNoise
        let base: Int
        switch pattern {
        case .resting:
            base = 60 + Int((sin(Double(index) / 9) * 3).rounded())
        case .intervals:
            let phase = index % 40
            base = phase < 20 ? 115 + phase * 3 : 175 - (phase - 20) * 4
        case .gradualRamp:
            base = min(170, 72 + index / 2)
        case .noisyArtifacts:
            base = 74 + Int((sin(Double(index) / 6) * 6).rounded())
        case .disconnectReconnect:
            base = 92 + Int((sin(Double(index) / 7) * 8).rounded())
        case .savedFixture:
            base = 0 // Returned above; keeps the exhaustive switch non-trapping.
        }

        let bpm = max(35, min(210, base + noise))
        var rr = 60_000 / Double(bpm)
        if pattern == .noisyArtifacts && index > 0 && index.isMultiple(of: 11) {
            rr = index.isMultiple(of: 22) ? 180 : 2_400
        } else {
            rr += (random.unit() - 0.5) * (pattern == .resting ? 36 : 18)
        }

        return SimulatedFrame(
            beatsPerMinute: bpm,
            rrMilliseconds: rr,
            startsInterruption: pattern == .disconnectReconnect && index > 0 && index.isMultiple(of: 30),
            endsInterruption: pattern == .disconnectReconnect && index > 0 && index % 30 == 4
        )
    }
}

protocol SimulatorStopBarrier: Sendable {
    func wait() async
    func restartObserved() async
}

actor SimulatedHeartRateSource: HeartRateDataSource {
    private let stream: AsyncStream<HeartRateDataEvent>
    private let continuation: AsyncStream<HeartRateDataEvent>.Continuation
    private let clock: any SolarClock
    private let playbackRate: Double
    private let stopBarrier: (any SimulatorStopBarrier)?
    private var generator: SimulatedSequenceGenerator
    private var task: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var interruptionID: UUID?
    private var generation = 0
    private var activeProducerCount = 0
    private var maximumProducerCount = 0

    init(
        pattern: SimulationPattern,
        seed: UInt64 = 0x534F_4C41_5248_39,
        playbackRate: Double = 1,
        clock: any SolarClock = SystemSolarClock(),
        savedFixture: [SimulatedFrame] = SimulatedSequenceGenerator.defaultFixture,
        eventBufferLimit: Int = 256,
        stopBarrier: (any SimulatorStopBarrier)? = nil
    ) {
        let pair = AsyncStream<HeartRateDataEvent>.makeStream(bufferingPolicy: .bufferingNewest(eventBufferLimit))
        stream = pair.stream
        continuation = pair.continuation
        generator = SimulatedSequenceGenerator(pattern: pattern, seed: seed, savedFixture: savedFixture)
        self.playbackRate = max(0.1, playbackRate)
        self.clock = clock
        self.stopBarrier = stopBarrier
    }

    func eventStream() async -> AsyncStream<HeartRateDataEvent> { stream }

    func start() async throws {
        if let stoppingTask {
            await stopBarrier?.restartObserved()
            let stoppingGeneration = generation
            await stoppingTask.value
            if generation == stoppingGeneration {
                task = nil
                self.stoppingTask = nil
            }
        }
        guard task == nil else { return }
        generation += 1
        let runGeneration = generation
        activeProducerCount += 1
        maximumProducerCount = max(maximumProducerCount, activeProducerCount)
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.emitNext(generation: runGeneration) == true else { break }
                let nanoseconds = await self?.delayNanoseconds ?? 1_000_000_000
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            await self?.producerFinished()
        }
    }

    func stop() async {
        generation += 1
        let stoppingGeneration = generation
        let stoppedTask = task
        stoppingTask = stoppedTask
        stoppedTask?.cancel()
        await stopBarrier?.wait()
        if let id = interruptionID {
            yield(.interruptionEnded(id: id, at: clock.nowUTC()))
            interruptionID = nil
        }
        await stoppedTask?.value
        if generation == stoppingGeneration {
            task = nil
            stoppingTask = nil
        }
    }

    private var delayNanoseconds: UInt64 { UInt64(1_000_000_000 / playbackRate) }

    func producerCountsForTesting() -> (active: Int, maximum: Int) {
        (activeProducerCount, maximumProducerCount)
    }

    private func producerFinished() { activeProducerCount = max(0, activeProducerCount - 1) }

    private func emitNext(generation runGeneration: Int) -> Bool {
        guard generation == runGeneration else { return false }
        let frame = generator.nextFrame()
        let now = clock.nowUTC()
        let monotonic = clock.monotonicNanoseconds()

        if frame.startsInterruption {
            let id = UUID()
            interruptionID = id
            yield(.interruptionStarted(id: id, at: now, reason: "Simulated connection gap"))
        } else if frame.endsInterruption, let id = interruptionID {
            yield(.interruptionEnded(id: id, at: now))
            interruptionID = nil
        } else if interruptionID == nil {
            let heartRate = HeartRateSampleValue(
                beatsPerMinute: frame.beatsPerMinute,
                receivedAtUTC: now,
                receivedMonotonicNanoseconds: monotonic,
                origin: .simulator
            )
            let rawTicks = UInt16(clamping: Int((frame.rrMilliseconds * 1_024 / 1_000).rounded()))
            let rr = RRIntervalValue(
                rawTicks1024: rawTicks,
                receivedAtUTC: now,
                receivedMonotonicNanoseconds: monotonic,
                derivedBeatTimeUTC: now,
                derivedBeatMonotonicNanoseconds: monotonic,
                origin: .simulator
            )
            yield(.heartRate(heartRate))
            yield(.rrIntervals([rr]))
        }
        return true
    }

    private func yield(_ event: HeartRateDataEvent) {
        if case .dropped = continuation.yield(event) {
            _ = continuation.yield(.dataLoss(at: clock.nowUTC(), reason: "Simulator event buffer overflow"))
        }
    }
}
