import Foundation
import Observation
import Combine
import Dispatch

@MainActor
@Observable
final class AppModel {
    enum Tab: Hashable {
        case live
        case today
        case trends
        case settings
    }

    enum SourceSelection: String, CaseIterable {
        case polarH9
        case simulator
    }

    var selectedTab: Tab = .live
    var presentDevicePickerOnLive = false
    var hasCompletedOnboarding: Bool
    var sourceSelection: SourceSelection {
        didSet { defaults.set(sourceSelection.rawValue, forKey: "sourceSelection") }
    }
    var maximumHeartRate: Int {
        didSet { defaults.set(maximumHeartRate, forKey: "maximumHeartRate") }
    }

    var isDemoModeEnabled: Bool {
        get { sourceSelection == .simulator }
        set { sourceSelection = newValue ? .simulator : .polarH9 }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        sourceSelection = SourceSelection(rawValue: defaults.string(forKey: "sourceSelection") ?? "") ?? .polarH9
        maximumHeartRate = defaults.integer(forKey: "maximumHeartRate")
    }

    func completeOnboarding(useDemoMode: Bool) {
        sourceSelection = useDemoMode ? .simulator : .polarH9
        hasCompletedOnboarding = true
        defaults.set(true, forKey: "hasCompletedOnboarding")
        selectedTab = .live
        presentDevicePickerOnLive = !useDemoMode
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
        defaults.set(false, forKey: "hasCompletedOnboarding")
    }
}

@MainActor
final class SensorCoordinator: ObservableObject {
    let sensor: PolarH9Client
    let recording: RecordingController?
    let persistenceError: String?
    @Published private(set) var currentHeartRate: Int?
    @Published private(set) var presentedOrigin: SampleOrigin?
    @Published private(set) var latestRRMilliseconds: Double?
    private var lastHeartRateMonotonicNanoseconds: UInt64?
    private var lastRRMonotonicNanoseconds: UInt64?
    private var sessionHeartRateSum = 0
    private var sessionHeartRateCount = 0
    private(set) var sessionMinimumHeartRate: Int?
    private(set) var sessionMaximumHeartRate: Int?
    @Published private(set) var liveHeartRatePoints: [HeartRateSampleValue] = []
    @Published private(set) var liveRRPoints: [RRIntervalValue] = []
    @Published private(set) var selectedSource: AppModel.SourceSelection = .polarH9
    @Published private(set) var isDemoRunning = false
    @Published private(set) var isLiveActivityActive = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitoringStartedAt: Date?
    @Published private(set) var workoutTargetZone: Int?
    private var monitoringActivityID: UUID?
    private var maximumHeartRate: Int?

    private var realConsumerTask: Task<Void, Never>?
    private var demoConsumerTask: Task<Void, Never>?
    private var qualityWatchdogTask: Task<Void, Never>?
    private var lastWatchdogQuality: HeartRateActivityAttributes.ContentState.ConnectionQuality?
    private var demoSource: SimulatedHeartRateSource?
    private var transitionGeneration = 0
    private var ingressSequence: UInt64 = 0
    private var didRecoverRecording = false
    private let liveActivity = HeartRateLiveActivityController()

    init(sensor: PolarH9Client, recording: RecordingController? = nil, persistenceError: String? = nil) {
        self.sensor = sensor; self.recording = recording; self.persistenceError = persistenceError
    }

    deinit {
        realConsumerTask?.cancel()
        demoConsumerTask?.cancel()
        qualityWatchdogTask?.cancel()
    }

    func activate() async {
        guard realConsumerTask == nil else { return }
        if !didRecoverRecording {
            didRecoverRecording = true
            await liveActivity.endOrphanedActivities()
            await recording?.recoverAtLaunch()
            if hasActiveRecording { hydrateLiveAggregatesFromRecoveredDraft(); startQualityWatchdog() }
            await syncLiveActivity()
        }
        realConsumerTask = Task { [weak self, sensor] in
            let events = await sensor.eventStream()
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .heartRate(let sample) = event {
                    await MainActor.run { [weak self] in
                    guard let self, self.selectedSource == .polarH9, sample.origin == .polarH9 else { return }
                    self.currentHeartRate = sample.beatsPerMinute
                    self.presentedOrigin = sample.origin
                    self.lastHeartRateMonotonicNanoseconds = sample.receivedMonotonicNanoseconds
                    self.lastWatchdogQuality = .good
                    }
                }
                await self?.route(event, origin: .polarH9)
            }
        }
    }

    func select(_ source: AppModel.SourceSelection) async {
        if (hasActiveRecording || isMonitoring), source != selectedSource { return }
        if selectedSource == source {
            if source == .simulator || !isDemoRunning { return }
        }
        transitionGeneration += 1
        let generation = transitionGeneration
        selectedSource = source
        currentHeartRate = nil
        presentedOrigin = nil
        if source == .simulator {
            await sensor.stop()
        } else {
            await stopDemo(invalidateTransition: false)
        }
        guard !Task.isCancelled, generation == transitionGeneration else { return }
    }

    func connectReal(deviceID: UUID) async {
        guard !hasActiveRecording, !isMonitoring else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        selectedSource = .polarH9
        currentHeartRate = nil
        presentedOrigin = nil
        await stopDemo(invalidateTransition: false)
        guard !Task.isCancelled, generation == transitionGeneration else { return }
        sensor.connect(deviceID: deviceID)
    }

    func toggleDemo() async {
        if isDemoRunning { await stopDemo(invalidateTransition: true) } else { await startDemo() }
    }

    private func startDemo() async {
        transitionGeneration += 1
        let generation = transitionGeneration
        isDemoRunning = true
        selectedSource = .simulator
        currentHeartRate = nil
        presentedOrigin = nil
        demoConsumerTask?.cancel()
        demoConsumerTask = nil
        if let demoSource { await demoSource.stop() }
        demoSource = nil
        await sensor.stop()
        guard !Task.isCancelled, generation == transitionGeneration, isDemoRunning else { return }
        let source = SimulatedHeartRateSource(pattern: .resting)
        demoSource = source
        demoConsumerTask = Task { [weak self] in
            let events = await source.eventStream()
            try? await source.start()
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .heartRate(let sample) = event, sample.origin == .simulator {
                    await MainActor.run { [weak self] in
                    guard let self, self.selectedSource == .simulator,
                          self.transitionGeneration == generation else { return }
                    self.currentHeartRate = sample.beatsPerMinute
                    self.presentedOrigin = sample.origin
                    self.lastHeartRateMonotonicNanoseconds = sample.receivedMonotonicNanoseconds
                    self.lastWatchdogQuality = .good
                    }
                }
                await self?.route(event, origin: .simulator)
            }
        }
    }

    private func stopDemo(invalidateTransition: Bool) async {
        if invalidateTransition { transitionGeneration += 1 }
        isDemoRunning = false
        demoConsumerTask?.cancel()
        demoConsumerTask = nil
        if let demoSource { await demoSource.stop() }
        demoSource = nil
        if selectedSource == .simulator {
            currentHeartRate = nil; latestRRMilliseconds = nil; presentedOrigin = nil
            lastHeartRateMonotonicNanoseconds = nil; lastRRMonotonicNanoseconds = nil
        }
    }

    private func route(_ event: HeartRateDataEvent, origin: SampleOrigin) async {
        guard (selectedSource == .polarH9 && origin == .polarH9) ||
                (selectedSource == .simulator && origin == .simulator) else { return }
        ingressSequence &+= 1
        let deviceID = origin == .polarH9 ? sensor.connectedDeviceID : nil
        await recording?.ingest(.init(sequence: ingressSequence, origin: origin,
                                      sensorDeviceID: deviceID, event: event))
        if case .heartRate(let sample) = event, isMonitoring || recording?.draft?.state == .recording {
            if recording?.draft?.state == .recording {
                sessionHeartRateSum += sample.beatsPerMinute; sessionHeartRateCount += 1
                sessionMinimumHeartRate = min(sessionMinimumHeartRate ?? sample.beatsPerMinute, sample.beatsPerMinute)
                sessionMaximumHeartRate = max(sessionMaximumHeartRate ?? sample.beatsPerMinute, sample.beatsPerMinute)
            }
            liveHeartRatePoints.append(sample)
            if liveHeartRatePoints.count > 120 { liveHeartRatePoints.removeFirst(liveHeartRatePoints.count - 120) }
            await syncLiveActivity(beatsPerMinute: sample.beatsPerMinute)
        }
        switch event {
        case .interruptionStarted, .dataLoss:
            currentHeartRate = nil; latestRRMilliseconds = nil
            lastHeartRateMonotonicNanoseconds = nil; lastRRMonotonicNanoseconds = nil
            await syncLiveActivity(beatsPerMinute: nil, forcedPhase: .reconnecting)
        default: break
        }
        if case .rrIntervals(let values) = event, let latest = values.last {
            latestRRMilliseconds = latest.milliseconds
            presentedOrigin = latest.origin
            lastRRMonotonicNanoseconds = latest.receivedMonotonicNanoseconds
            if isMonitoring || recording?.draft?.state == .recording {
                liveRRPoints.append(contentsOf: values)
                if liveRRPoints.count > 180 { liveRRPoints.removeFirst(liveRRPoints.count - 180) }
            }
        }
    }

    func startWorkout() async {
        if isMonitoring { await stopMonitoring() }
        await startSession(purpose: .exerciseSession)
    }

    func configureMaximumHeartRate(_ value: Int?) {
        maximumHeartRate = value.flatMap { $0 >= 100 ? $0 : nil }
    }

    func configureReducedAnimation(_ value: Bool) {
        liveActivity.configureReducedMotion(value)
        if isMonitoring || hasActiveRecording { Task { await syncLiveActivity() } }
    }

    func setWorkoutTargetZone(_ zone: Int?) {
        workoutTargetZone = zone.flatMap { (1...5).contains($0) ? $0 : nil }
        Task { await syncLiveActivity() }
    }

    func startMonitoring() async {
        guard !hasActiveRecording, !isMonitoring, sourceIsReady else { return }
        isMonitoring = true
        monitoringStartedAt = Date()
        monitoringActivityID = UUID()
        liveHeartRatePoints = []; liveRRPoints = []
        sessionHeartRateSum = 0; sessionHeartRateCount = 0
        sessionMinimumHeartRate = nil; sessionMaximumHeartRate = nil
        startQualityWatchdog()
        await syncLiveActivity()
    }

    func stopMonitoring() async {
        guard isMonitoring else { return }
        isMonitoring = false
        monitoringStartedAt = nil
        monitoringActivityID = nil
        qualityWatchdogTask?.cancel(); qualityWatchdogTask = nil
        lastWatchdogQuality = nil
        await liveActivity.end()
        isLiveActivityActive = false
    }

    private func startSession(purpose: MeasurementPurpose) async {
        sessionHeartRateSum = 0; sessionHeartRateCount = 0
        sessionMinimumHeartRate = nil; sessionMaximumHeartRate = nil
        liveHeartRatePoints = []; liveRRPoints = []
        let origin: SampleOrigin = selectedSource == .simulator ? .simulator : .polarH9
        await recording?.start(purpose: purpose, origin: origin,
                               sensorDeviceID: origin == .polarH9 ? sensor.connectedDeviceID : nil)
        startQualityWatchdog()
        await syncLiveActivity()
    }

    func pauseOrResume() async {
        guard let recording else { return }
        switch recording.status {
        case .recording: await recording.pause(sequence: ingressSequence)
        case .paused: await recording.resume(sequence: ingressSequence)
        default: break
        }
        await syncLiveActivity()
    }

    func endWorkout() async {
        await recording?.end(sequence: ingressSequence)
        await finishLiveActivityIfSessionEnded()
    }

    func cancelCheckIn() async {
        await recording?.cancel(sequence: ingressSequence)
        await finishLiveActivityIfSessionEnded()
    }

    func acknowledgeRecordingFailure() { recording?.acknowledgeFailure() }

    func resetAfterDataDeletion() async {
        guard !hasActiveRecording else { return }
        await stopDemo(invalidateTransition: true)
        await sensor.stop()
        sensor.forgetDevice()
        await liveActivity.end()
        isLiveActivityActive = false
        qualityWatchdogTask?.cancel(); qualityWatchdogTask = nil
        lastWatchdogQuality = nil
        isMonitoring = false; monitoringStartedAt = nil; monitoringActivityID = nil
        recording?.resetAfterDataDeletion()
        selectedSource = .polarH9
        currentHeartRate = nil; latestRRMilliseconds = nil
        lastHeartRateMonotonicNanoseconds = nil; lastRRMonotonicNanoseconds = nil
        presentedOrigin = nil
        liveHeartRatePoints = []; liveRRPoints = []
        sessionHeartRateSum = 0; sessionHeartRateCount = 0
        sessionMinimumHeartRate = nil; sessionMaximumHeartRate = nil
    }

    var currentHeartRateResult: MetricResult? {
        guard let currentHeartRate, let presentedOrigin else { return nil }
        if presentedOrigin == .polarH9 {
            guard case .connected = sensor.state,
                  let received = lastHeartRateMonotonicNanoseconds else { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= received, now - received <= 5_000_000_000 else { return nil }
        } else if !isDemoRunning { return nil }
        return try? MetricResult(id: "live_hr", name: "Current heart rate", value: Double(currentHeartRate), unit: "bpm",
                                 classification: .measured, context: recording?.draft?.purpose ?? .exerciseSession,
                                 lineage: .init(sampleOrigins: [presentedOrigin]), algorithmVersion: "hrs-measurement-v1",
                                 configurationVersion: "bluetooth-hrs-v1", quality: .good, reasons: [])
    }

    var latestRRResult: MetricResult? {
        guard let latestRRMilliseconds, let presentedOrigin else { return nil }
        if presentedOrigin == .polarH9 {
            guard case .connected = sensor.state, let received = lastRRMonotonicNanoseconds else { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= received, now - received <= 5_000_000_000 else { return nil }
        } else if !isDemoRunning { return nil }
        return try? MetricResult(id: "live_rr", name: "Latest RR interval", value: latestRRMilliseconds, unit: "ms",
                                 classification: .measured, context: recording?.draft?.purpose ?? .exerciseSession,
                                 lineage: .init(sampleOrigins: [presentedOrigin]), algorithmVersion: "hrs-rr-v1",
                                 configurationVersion: "ticks-1024-v1", quality: .good, reasons: [])
    }

    var sessionAverageHeartRateResult: MetricResult? {
        guard sessionHeartRateCount > 0, let presentedOrigin else { return nil }
        return try? MetricResult(id: "live_average_hr", name: "Session average", value: Double(sessionHeartRateSum) / Double(sessionHeartRateCount),
                                 unit: "bpm", classification: .calculated,
                                 context: recording?.draft?.purpose ?? .exerciseSession,
                                 lineage: .init(sampleOrigins: [presentedOrigin]), algorithmVersion: "stream-average-v1",
                                 configurationVersion: "stream-average-v1", quality: .good, reasons: [])
    }

    func flushForBackground() async {
        await recording?.flushForBackground()
        await syncLiveActivity()
    }

    private func syncLiveActivity(
        beatsPerMinute: Int? = nil,
        forcedPhase: HeartRateActivityAttributes.ContentState.Phase? = nil
    ) async {
        guard isMonitoring || hasActiveRecording else { return }
        let draft = recording?.draft
        let mode: HeartRateActivityAttributes.Mode = hasActiveRecording ? .workout : .monitoring
        let activityID = draft?.id ?? monitoringActivityID
        let startedAt = draft?.startedAtUTC ?? monitoringStartedAt
        guard let activityID, let startedAt else { return }
        let phase = forcedPhase ?? (hasActiveRecording ? liveActivityPhase(for: recording?.status ?? .idle) : .recording)
        let average = mode == .monitoring || sessionHeartRateCount == 0 ? nil :
            Int((Double(sessionHeartRateSum) / Double(sessionHeartRateCount)).rounded())
        let bpm = beatsPerMinute ?? (phase == .reconnecting ? nil : currentHeartRate)
        let zone = bpm.flatMap(currentZone)
        let quality = connectionQuality

        if !liveActivity.isActive {
            await liveActivity.start(
                activityID: activityID,
                startedAt: startedAt,
                mode: mode,
                origin: draft?.origin ?? presentedOrigin ?? (selectedSource == .simulator ? .simulator : .polarH9),
                beatsPerMinute: bpm,
                averageBeatsPerMinute: average,
                zone: zone,
                targetZone: mode == .workout ? workoutTargetZone : nil,
                connectionQuality: quality
            )
        }
        await liveActivity.update(
            beatsPerMinute: bpm,
            averageBeatsPerMinute: average,
            phase: phase,
            zone: zone,
            targetZone: mode == .workout ? workoutTargetZone : nil,
            connectionQuality: quality
        )
        isLiveActivityActive = liveActivity.isActive
    }

    private func finishLiveActivityIfSessionEnded() async {
        guard let recording else { return }
        if case .completed = recording.status {
            await liveActivity.end()
            isLiveActivityActive = false
            qualityWatchdogTask?.cancel(); qualityWatchdogTask = nil
        } else {
            await syncLiveActivity()
        }
    }

    private func liveActivityPhase(for status: RecordingStatus) -> HeartRateActivityAttributes.ContentState.Phase {
        switch status {
        case .paused: .paused
        case .degraded: .reconnecting
        case .ending: .saving
        default: .recording
        }
    }

    func currentZone(for bpm: Int) -> Int? {
        guard let maximumHeartRate else { return nil }
        return HeartRateZoneConfiguration.standard(maximumHeartRate: maximumHeartRate, source: .measured,
                                                   effectiveAtUTC: Date()).zone(for: bpm)
    }

    var connectionQuality: HeartRateActivityAttributes.ContentState.ConnectionQuality {
        if selectedSource == .simulator { return isDemoRunning ? .good : .disconnected }
        let connected: Bool
        let reconnecting: Bool
        switch sensor.state {
        case .connected: connected = true; reconnecting = false
        case .reconnecting: connected = false; reconnecting = true
        default: connected = false; reconnecting = false
        }
        return HeartRateSignalQualityEvaluator.evaluate(connected: connected, reconnecting: reconnecting,
                                                        lastSampleNanoseconds: lastHeartRateMonotonicNanoseconds,
                                                        nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    var sourceIsReady: Bool {
        if selectedSource == .simulator { return isDemoRunning }
        if case .connected = sensor.state { return true }
        return false
    }

    private func startQualityWatchdog() {
        qualityWatchdogTask?.cancel()
        lastWatchdogQuality = connectionQuality
        qualityWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isMonitoring || self.hasActiveRecording else { return }
                let quality = self.connectionQuality
                guard quality != self.lastWatchdogQuality else { continue }
                self.lastWatchdogQuality = quality
                if quality != .good { self.currentHeartRate = nil }
                await self.syncLiveActivity(forcedPhase: quality == .good ? nil : .reconnecting)
            }
        }
    }

    private func hydrateLiveAggregatesFromRecoveredDraft() {
        guard let draft = recording?.draft else { return }
        sessionHeartRateSum = draft.heartRates.reduce(0) { $0 + $1.beatsPerMinute }
        sessionHeartRateCount = draft.heartRates.count
        sessionMinimumHeartRate = draft.heartRates.map(\.beatsPerMinute).min()
        sessionMaximumHeartRate = draft.heartRates.map(\.beatsPerMinute).max()
        liveHeartRatePoints = Array(draft.heartRates.suffix(120))
        liveRRPoints = Array(draft.rrIntervals.suffix(180))
        presentedOrigin = draft.origin
    }

    var hasActiveRecording: Bool {
        guard let recording else { return false }
        switch recording.status {
        case .recording, .paused, .ending, .degraded: return true
        default: return false
        }
    }
}

enum HeartRateSignalQualityEvaluator {
    static func evaluate(connected: Bool, reconnecting: Bool, lastSampleNanoseconds: UInt64?,
                         nowNanoseconds: UInt64) -> HeartRateActivityAttributes.ContentState.ConnectionQuality {
        if reconnecting { return .poor }
        guard connected else { return .disconnected }
        guard let lastSampleNanoseconds, nowNanoseconds >= lastSampleNanoseconds else { return .poor }
        let age = nowNanoseconds - lastSampleNanoseconds
        if age <= 3_000_000_000 { return .good }
        return age <= 10_000_000_000 ? .poor : .disconnected
    }
}
