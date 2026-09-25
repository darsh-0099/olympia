import Charts
import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var appModel
    @EnvironmentObject private var coordinator: SensorCoordinator
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.solarTheme) private var theme
    @State private var showDevicePicker = false
    @State private var selectedOverview: SessionOverview?

    var body: some View {
        NavigationStack {
            ZStack {
                SolarBackground()
                ScrollView {
                    VStack(spacing: SolarSpace.md) {
                        HStack {
                            StatusChip(title: statusText, isDemo: appModel.isDemoModeEnabled)
                                .accessibilityIdentifier("live.connectionState")
                            Spacer()
                            if coordinator.isLiveActivityActive {
                                Label("ISLAND LIVE", systemImage: "capsule.portrait.fill")
                                    .font(.caption2.bold())
                                    .tracking(1.2)
                                    .foregroundStyle(theme.secondaryAccent)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            LiveHeartHero(
                                heartRate: coordinator.currentHeartRateResult,
                                latestRR: coordinator.latestRRResult,
                                isRecording: coordinator.hasActiveRecording || coordinator.isMonitoring,
                                title: (coordinator.hasActiveRecording || coordinator.isMonitoring) ? activeTitle : "Heart rate"
                            )
                        }

                        SolarCard {
                            SolarZoneLadder(snapshot: zoneSnapshot)
                        }

                        if coordinator.hasActiveRecording {
                            SolarCard {
                                Text("Workout target").font(.headline)
                                Picker("Target zone", selection: Binding(
                                    get: { coordinator.workoutTargetZone ?? 0 },
                                    set: { coordinator.setWorkoutTargetZone($0 == 0 ? nil : $0) }
                                )) {
                                    Text("Open").tag(0)
                                    ForEach(1...5, id: \.self) { Text("Zone \($0)").tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        if let recording = coordinator.recording, coordinator.hasActiveRecording {
                            SessionStatsRow(coordinator: coordinator, recording: recording)
                        }

                        SolarCard {
                            Label(coordinator.hasActiveRecording ? activeTitle : "Ready when you are",
                                  systemImage: coordinator.hasActiveRecording ? "record.circle" : "sparkles")
                                .font(.headline)
                                .foregroundStyle(theme.primaryText)
                            Text(activeDetail)
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                                .padding(.top, SolarSpace.xs)
                        }

                        if (coordinator.hasActiveRecording || coordinator.isMonitoring), !coordinator.liveHeartRatePoints.isEmpty {
                            LiveChartCard(title: "Heart rate", detail: "Last two minutes", color: theme.accent) {
                                Chart(coordinator.liveHeartRatePoints) { sample in
                                    AreaMark(x: .value("Time", sample.receivedAtUTC),
                                             y: .value("Heart rate", sample.beatsPerMinute))
                                        .foregroundStyle(.linearGradient(
                                            colors: [theme.accent.opacity(0.34), theme.accent.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom
                                        ))
                                    LineMark(x: .value("Time", sample.receivedAtUTC),
                                             y: .value("Heart rate", sample.beatsPerMinute))
                                        .foregroundStyle(theme.accent)
                                        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                        .interpolationMethod(.catmullRom)
                                }
                                .chartXAxis(.hidden)
                                .chartYAxis { AxisMarks(position: .leading) }
                                .frame(height: 160)
                                .accessibilityLabel("Rolling heart-rate chart")
                                .accessibilityValue("\(coordinator.liveHeartRatePoints.count) recent samples")
                            }
                        }

                        if (coordinator.hasActiveRecording || coordinator.isMonitoring), !coordinator.liveRRPoints.isEmpty {
                            LiveChartCard(title: "Beat intervals", detail: "RR variability", color: theme.secondaryAccent) {
                                Chart(coordinator.liveRRPoints) { sample in
                                    PointMark(x: .value("Time", sample.receivedAtUTC),
                                              y: .value("RR milliseconds", sample.milliseconds))
                                        .foregroundStyle(theme.secondaryAccent)
                                        .symbolSize(22)
                                }
                                .chartXAxis(.hidden)
                                .frame(height: 120)
                                .accessibilityLabel("Recent RR interval tachogram")
                                .accessibilityValue("\(coordinator.liveRRPoints.count) recent RR intervals")
                            }
                        }

                        if let recording = coordinator.recording {
                            MonitoringControls()
                            RecordingControls(recording: recording) { sessionID in
                                Task {
                                    await productStore.refresh()
                                    if let session = productStore.allSessions.first(where: { $0.id == sessionID }) {
                                        selectedOverview = ProductStore.makeOverview(session)
                                    }
                                }
                            }
                        }

                        if !coordinator.hasActiveRecording && !coordinator.isMonitoring {
                            Button(appModel.isDemoModeEnabled ? (coordinator.isDemoRunning ? "Stop demo" : "Start demo source") : "Connect heart-rate sensor") {
                                if appModel.isDemoModeEnabled { Task { await coordinator.toggleDemo() } }
                                else { showDevicePicker = true; coordinator.sensor.scan() }
                            }
                            .buttonStyle(SolarPrimaryButtonStyle())
                            .accessibilityIdentifier(appModel.isDemoModeEnabled ? "live.startDemo" : "live.connectH9")
                        }
                    }
                    .padding(.horizontal, SolarSpace.md)
                    .padding(.bottom, SolarSpace.xl)
                }
            }
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showDevicePicker) { DevicePickerView() }
            .sheet(item: $selectedOverview, onDismiss: { coordinator.recording?.resetAfterSummary() }) { overview in
                NavigationStack { SessionSummaryView(overview: overview) }
                    .environmentObject(productStore)
            }
            .onAppear {
                if appModel.presentDevicePickerOnLive {
                    appModel.presentDevicePickerOnLive = false
                    showDevicePicker = true
                }
            }
        }
    }

    private var activeTitle: String {
        if coordinator.isMonitoring { return "Passive monitoring" }
        return "Workout in progress"
    }

    private var activeDetail: String {
        if coordinator.hasActiveRecording {
            return appModel.isDemoModeEnabled ? "SIMULATED • Demo samples stay outside real trends." :
                "Keep the strap connected. Pauses and connection gaps are stored explicitly."
        }
        if coordinator.isMonitoring {
            return "Live Activity is active. Monitoring is transient and does not create a saved workout."
        }
        return appModel.isDemoModeEnabled ? "Start a clearly marked simulated session." :
            "Connect a compatible Heart Rate Service sensor, including Polar or a device broadcasting heart rate."
    }

    private var zoneSnapshot: SolarZoneSnapshot {
        let bpm = coordinator.currentHeartRateResult?.value.map { Int($0.rounded()) }
        return .init(beatsPerMinute: bpm, currentZone: bpm.flatMap(coordinator.currentZone),
                     targetZone: coordinator.hasActiveRecording ? coordinator.workoutTargetZone : nil)
    }

    private var statusText: String {
        if appModel.isDemoModeEnabled { return coordinator.isDemoRunning ? "DEMO • SIMULATED" : "DEMO READY" }
        switch coordinator.sensor.state {
        case .connected:
            switch coordinator.connectionQuality {
            case .good: return "GOOD SIGNAL"
            case .poor: return "SIGNAL DELAYED"
            case .disconnected: return "NO HEART-RATE DATA"
            }
        case .connecting: return "CONNECTING"
        case .reconnecting: return "RECONNECTING"
        case .scanning: return "SCANNING"
        case .unauthorized: return "BLUETOOTH DENIED"
        case .bluetoothUnavailable: return "BLUETOOTH UNAVAILABLE"
        case .error: return "CONNECTION ERROR"
        case .disconnected: return "DISCONNECTED"
        }
    }

}

private struct MonitoringControls: View {
    @EnvironmentObject private var coordinator: SensorCoordinator
    @Environment(\.solarTheme) private var theme

    var body: some View {
        SolarCard {
            Text("Monitoring").font(.headline)
            Text("A fluid, glanceable heart-rate view on this screen, the Lock Screen, and Dynamic Island. It is separate from saved workouts.")
                .font(.subheadline).foregroundStyle(theme.secondaryText)
            Button(coordinator.isMonitoring ? "Stop Monitoring" : "Start Monitoring") {
                Task {
                    if coordinator.isMonitoring { await coordinator.stopMonitoring() }
                    else { await coordinator.startMonitoring() }
                }
            }
            .buttonStyle(SolarPrimaryButtonStyle())
            .padding(.top, SolarSpace.sm)
            .disabled(coordinator.hasActiveRecording || (!coordinator.isMonitoring && !coordinator.sourceIsReady))
            .accessibilityIdentifier("live.toggleMonitoring")
        }
    }
}

private struct StatusChip: View {
    @Environment(\.solarTheme) private var theme
    let title: String
    let isDemo: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isDemo ? theme.secondaryAccent : theme.accent)
                .frame(width: 7, height: 7)
                .shadow(color: isDemo ? theme.secondaryAccent : theme.accent, radius: 5)
            Text(title)
                .font(.caption2.bold())
                .tracking(1.4)
        }
        .foregroundStyle(isDemo ? theme.secondaryAccent : theme.accent)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.055), in: Capsule())
        .overlay { Capsule().stroke(Color.white.opacity(0.08)) }
    }
}

private struct LiveHeartHero: View {
    @Environment(\.solarTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let heartRate: MetricResult?
    let latestRR: MetricResult?
    let isRecording: Bool
    let title: String

    private var beatsPerMinute: Int? { heartRate?.value.map { Int($0) } }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.elevated, theme.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(theme.accent.opacity(0.14))
                .frame(width: 230, height: 230)
                .blur(radius: 18)
                .offset(x: 120, y: -95)
            Circle()
                .stroke(theme.accent.opacity(0.12), lineWidth: 1)
                .frame(width: 180, height: 180)
                .offset(x: 112, y: -82)

            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    heartIcon
                    Text(title.uppercased())
                        .font(.caption2.bold())
                        .tracking(1.6)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Text(beatsPerMinute.map(String.init) ?? "—")
                    .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(theme.primaryText)

                Text("BPM")
                    .font(.caption.bold())
                    .tracking(2.4)
                    .foregroundStyle(theme.accent)

                if let rr = latestRR, let value = rr.value {
                    Label("\(Int(value.rounded())) ms between beats", systemImage: "waveform.path.ecg")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 5)
                        .accessibilityIdentifier("live.latestRR")
                } else {
                    Text(heartRate == nil ? "Waiting for a fresh signal" : "RR interval unavailable")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 5)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, SolarSpace.md)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.08)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(beatsPerMinute.map { "Current heart rate, \($0) beats per minute" }
                            ?? "Current heart rate unavailable or stale")
    }

    @ViewBuilder private var heartIcon: some View {
        let image = Image(systemName: isRecording ? "heart.fill" : "heart").foregroundStyle(theme.accent)
        if systemReduceMotion || theme.reducedAnimation { image } else { image.symbolEffect(.pulse, value: beatsPerMinute) }
    }
}

private struct SessionStatsRow: View {
    @Environment(\.solarTheme) private var theme
    @ObservedObject var coordinator: SensorCoordinator
    @ObservedObject var recording: RecordingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: SolarSpace.sm) {
                stat(title: "TIME", value: elapsedText, symbol: "timer")
                stat(title: "AVERAGE", value: averageText, symbol: "heart.text.square")
                stat(title: "RANGE", value: rangeText, symbol: "arrow.up.and.down")
            }
        }
        .accessibilityIdentifier("live.elapsed")
    }

    private var elapsedText: String {
        let elapsed = max(0, Int(recording.elapsedRecordingSeconds))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private var averageText: String {
        guard let value = coordinator.sessionAverageHeartRateResult?.value else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private var rangeText: String {
        guard let minimum = coordinator.sessionMinimumHeartRate,
              let maximum = coordinator.sessionMaximumHeartRate else { return "—" }
        return "\(minimum)–\(maximum)"
    }

    private func stat(title: String, value: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(theme.secondaryAccent)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(theme.primaryText)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)) }
    }
}

private struct LiveChartCard<Content: View>: View {
    @Environment(\.solarTheme) private var theme
    let title: String
    let detail: String
    let color: Color
    let content: Content

    init(title: String, detail: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.color = color
        self.content = content()
    }

    var body: some View {
        SolarCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 4)
            }
            content.padding(.top, SolarSpace.md)
        }
    }
}

private struct RecordingControls: View {
    @EnvironmentObject private var coordinator: SensorCoordinator
    @ObservedObject var recording: RecordingController
    @Environment(\.solarTheme) private var theme
    let showSummary: (UUID) -> Void

    var body: some View {
        VStack(spacing: SolarSpace.sm) {
            switch recording.status {
            case .idle:
                Button("Start workout") { Task { await coordinator.startWorkout() } }
                    .buttonStyle(SolarSecondaryButtonStyle())
                    .disabled(!sourceIsReady || coordinator.isMonitoring)
            case .completed(let id):
                Button("View saved session") { showSummary(id) }
                    .buttonStyle(SolarSecondaryButtonStyle())
            case .recording:
                HStack {
                    Button("Pause") { Task { await coordinator.pauseOrResume() } }
                    Button("End", role: .destructive) { Task { await coordinator.endWorkout() } }
                }
                .buttonStyle(SolarSecondaryButtonStyle())
            case .paused:
                HStack {
                    Button("Resume") { Task { await coordinator.pauseOrResume() } }
                    Button("End", role: .destructive) { Task { await coordinator.endWorkout() } }
                }
                .buttonStyle(SolarSecondaryButtonStyle())
            case .ending:
                ProgressView("Saving session…")
            case .degraded(_, let message):
                VStack {
                    Text(message).font(.footnote).foregroundStyle(theme.accent)
                    Button("Retry and end") { Task { await coordinator.endWorkout() } }
                }
            case .failed(let message):
                VStack {
                    Text(message).font(.footnote).foregroundStyle(theme.accent)
                    if recording.draft == nil {
                        Button("Try again") { coordinator.acknowledgeRecordingFailure() }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var sourceIsReady: Bool {
        if coordinator.selectedSource == .simulator { return coordinator.isDemoRunning }
        if case .connected = coordinator.sensor.state { return true }
        return false
    }
}

@MainActor
private func demoPreviewDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "preview.live.demo")!
    defaults.set(AppModel.SourceSelection.simulator.rawValue, forKey: "sourceSelection")
    return defaults
}

#Preview("Demo source") {
    let defaults = demoPreviewDefaults()
    LiveView()
        .environment(AppModel(defaults: defaults))
        .environmentObject(SensorCoordinator(sensor: PolarH9Client(defaults: defaults)))
        .environmentObject(ProductStore(repository: nil))
}

#Preview("Disconnected") {
    LiveView()
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.live.disconnected")!))
        .environmentObject(SensorCoordinator(sensor: PolarH9Client(defaults: UserDefaults(suiteName: "preview.live.sensor")!)))
        .environmentObject(ProductStore(repository: nil))
}

#Preview("Passive monitoring") {
    SolarExperienceStatePreview(title: "Monitoring", bpm: 128, zone: 2, quality: "Good signal", target: nil)
}

#Preview("Formal workout") {
    SolarExperienceStatePreview(title: "Workout", bpm: 166, zone: 4, quality: "Good signal", target: 4)
}

#Preview("Poor connection") {
    SolarExperienceStatePreview(title: "Monitoring", bpm: 128, zone: 2, quality: "Signal delayed", target: nil)
}

private struct SolarExperienceStatePreview: View {
    let title: String
    let bpm: Int
    let zone: Int
    let quality: String
    let target: Int?

    var body: some View {
        ZStack {
            SolarBackground()
            VStack(spacing: 16) {
                HStack { Label(title, systemImage: "heart.fill"); Spacer(); Text(quality).foregroundStyle(SolarColor.status) }
                SolarZoneLadder(snapshot: .init(beatsPerMinute: bpm, currentZone: zone, targetZone: target))
                Button(title == "Workout" ? "End Workout" : "Stop Monitoring") { }
                    .buttonStyle(SolarPrimaryButtonStyle())
            }.padding().background(SolarColor.surface, in: RoundedRectangle(cornerRadius: 24)).padding()
        }
    }
}
