import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @EnvironmentObject private var coordinator: SensorCoordinator
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.solarTheme) private var theme
    @State private var showResetConfirmation = false
    @State private var showDevicePicker = false

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            ZStack {
                SolarBackground()
                Form {
                    Section("Experience") {
                        NavigationLink("Appearance Lab") { AppearanceLabView() }
                            .accessibilityIdentifier("settings.appearanceLab")
                    }

                    Section("Sensor") {
                        LabeledContent("Compatible hardware", value: "Bluetooth Heart Rate Service sensors")
                        Toggle("Demo mode", isOn: $appModel.isDemoModeEnabled)
                            .disabled(coordinator.hasActiveRecording || coordinator.isMonitoring)
                            .accessibilityHint(coordinator.hasActiveRecording ? "End the active recording before changing sources" : "Uses clearly labeled simulated data")
                            .accessibilityIdentifier("settings.demoMode")
                        Button("Manage devices") { showDevicePicker = true }
                            .accessibilityIdentifier("settings.manageDevices")
                    }

                    Section("Training zones") {
                        Toggle("Use a personal maximum HR", isOn: Binding(
                            get: { appModel.maximumHeartRate >= 100 },
                            set: { appModel.maximumHeartRate = $0 ? 190 : 0 }
                        ))
                        if appModel.maximumHeartRate >= 100 {
                            Stepper(value: $appModel.maximumHeartRate, in: 100...240, step: 1) {
                                LabeledContent("Personal maximum HR", value: "\(appModel.maximumHeartRate) bpm")
                            }
                        }
                        Text("The H9 does not provide maximum heart rate. Enter a measured personal maximum to enable zone load, or leave this unset.")
                            .font(.footnote).foregroundStyle(theme.secondaryText)
                    }

                    Section("Data & privacy") {
                        NavigationLink("What SolarH9 stores") {
                            PrivacySummaryView()
                        }
                        Button("Prepare export files") { Task { await productStore.prepareExport() } }
                            .accessibilityIdentifier("settings.export")
                        ForEach(productStore.exportFiles, id: \.self) { file in
                            ShareLink(item: file) { Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up") }
                        }
                        if let error = productStore.errorMessage { Text(error).foregroundStyle(theme.accent) }
                        Button("Prepare sanitized diagnostics") { Task { await productStore.prepareDiagnostics() } }
                            .accessibilityHint("Contains fixed app state codes only, never heart-rate samples, RR values, or journal text")
                        NavigationLink("Session history") {
                            List(productStore.realSessions) { overview in
                                NavigationLink {
                                    SessionSummaryView(overview: overview)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(overview.session.purpose == .restingCheckIn ? "Resting check-in" : "Workout")
                                        Text(overview.session.startedAtUTC.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.navigationTitle("Real sessions")
                        }
                        Button("Delete all data", role: .destructive) {
                            showResetConfirmation = true
                        }
                        .accessibilityIdentifier("settings.deleteAll")
                        .disabled(coordinator.hasActiveRecording || coordinator.isMonitoring)
                        .accessibilityHint(coordinator.hasActiveRecording ? "End the active recording first" : "Deletes local SolarH9 data after confirmation")
                    }

                    Section("About") {
                        NavigationLink("About these metrics") {
                            MetricAboutView()
                        }
                        Text("SolarH9 is an independent wellness app and is not affiliated with or endorsed by Polar Electro or WHOOP.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                        Text("Not a medical device. Not for diagnosis or emergency monitoring.")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .fullScreenCover(isPresented: $showDevicePicker) { DevicePickerView() }
            .confirmationDialog("Delete all SolarH9 data?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    Task {
                        if await productStore.deleteAll() {
                            await coordinator.resetAfterDataDeletion()
                            appModel.maximumHeartRate = 0
                            appModel.sourceSelection = .polarH9
                            productStore.configureMaximumHeartRate(nil)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot remove archives you already shared outside SolarH9.")
            }
        }
        .task { await productStore.refresh() }
        .onChange(of: appModel.maximumHeartRate) { _, value in
            productStore.configureMaximumHeartRate(value == 0 ? nil : value)
            Task { await productStore.refresh() }
        }
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.settings")!))
        .environmentObject(SensorCoordinator(sensor: PolarH9Client(defaults: UserDefaults(suiteName: "preview.settings.sensor")!)))
        .environmentObject(ProductStore(repository: nil))
        .environmentObject(SolarThemeStore(defaults: UserDefaults(suiteName: "preview.settings.theme")!))
}

struct DevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @EnvironmentObject private var coordinator: SensorCoordinator

    var body: some View {
        DevicePickerContent(sensor: coordinator.sensor, allowsChanges: !coordinator.hasActiveRecording) { id in
            appModel.sourceSelection = .polarH9
            Task { await coordinator.connectReal(deviceID: id) }
        }
    }
}

private struct DevicePickerContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var sensor: PolarH9Client
    let allowsChanges: Bool
    let connect: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section { connectionStateBanner }
                Section {
                    if sensor.discoveredDevices.isEmpty {
                        emptyState
                    }
                    ForEach(sensor.discoveredDevices) { device in
                        Button {
                            connect(device.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text("ID …\(device.identifierSuffix)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.isKnown { Image(systemName: "checkmark.circle.fill").foregroundStyle(SolarColor.sun) }
                                Text(device.rssi.map { "\($0) dBm" } ?? "Signal —")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!canConnect || !allowsChanges)
                    }
                } header: { Text("Heart Rate Service devices") }

                Section {
                    Button("Disconnect") { sensor.disconnect() }.disabled(!allowsChanges)
                    Button("Forget saved sensor", role: .destructive) { sensor.forgetDevice() }.disabled(!allowsChanges)
                }
            }
            .navigationTitle("Heart-rate sensor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan") { sensor.scan() }
                        .disabled(!canScan)
                }
            }
            .task { sensor.scan() }
        }
    }

    private var canScan: Bool {
        switch sensor.state {
        case .unauthorized, .bluetoothUnavailable: return false
        default: return true
        }
    }

    private var canConnect: Bool {
        switch sensor.state {
        case .unauthorized, .bluetoothUnavailable, .connecting, .reconnecting: return false
        default: return true
        }
    }

    @ViewBuilder private var connectionStateBanner: some View {
        switch sensor.state {
        case .unauthorized:
            VStack(alignment: .leading) {
                Label("Bluetooth permission is denied. Enable it in iPhone Settings.", systemImage: "lock.fill")
                Button("Open iPhone Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .bluetoothUnavailable:
            Label("Bluetooth is unavailable. Turn it on to continue.", systemImage: "antenna.radiowaves.left.and.right.slash")
        case .scanning:
            Label("Scanning for Heart Rate Service devices…", systemImage: "dot.radiowaves.left.and.right")
        case .connecting:
            Label("Connecting to the selected sensor…", systemImage: "link")
        case .reconnecting:
            Label("Connection lost. Retrying…", systemImage: "arrow.clockwise")
        case .connected:
            Label("Sensor connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SolarColor.status)
        case .disconnected:
            Label("Choose a nearby Bluetooth heart-rate sensor.", systemImage: "heart.circle")
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch sensor.state {
        case .unauthorized:
            ContentUnavailableView("Bluetooth access denied", systemImage: "lock.fill",
                                   description: Text("Allow Bluetooth for Olympia in iPhone Settings, then return here."))
        case .bluetoothUnavailable:
            ContentUnavailableView("Bluetooth unavailable", systemImage: "antenna.radiowaves.left.and.right.slash",
                                   description: Text("Turn on Bluetooth, then return here."))
        case .error(let message):
            ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .connecting, .reconnecting:
            ContentUnavailableView("Connecting", systemImage: "link", description: Text("Keep the strap nearby."))
        case .connected:
            ContentUnavailableView("Connected", systemImage: "checkmark.circle", description: Text("The saved sensor is ready."))
        default:
            ContentUnavailableView("Searching for sensors", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("Wear or activate your sensor's heart-rate broadcast and keep it nearby."))
        }
    }
}

private struct PrivacySummaryView: View {
    var body: some View {
        List {
            Text("SolarH9 stores sessions, heart-rate samples, raw RR interval ticks, check-ins, journal entries, profile settings, and algorithm metadata locally on this iPhone.")
            Text("No account, advertising SDK, analytics, or required server is used.")
            Text("Health samples are excluded from diagnostic logs by default.")
            Text("Exports you share leave SolarH9’s control. Deleting in-app data cannot remove shared copies or device backups.")
            Text("The local store is protected for after-first-unlock access so a recording you started can continue while the phone is locked; export files use complete protection.")
            Text("SolarH9 is not a medical device and is not for diagnosis or emergency monitoring.")
        }
        .navigationTitle("Local data")
    }
}

private struct MetricAboutView: View {
    var body: some View {
        List {
            metric("Measured", "Heart rate and RR intervals arrive from the compatible sensor. Raw samples are preserved.")
            metric("Calculated", "HRV, zones, and training load use documented formulas and quality gates.")
            metric("Estimated", "Solar Readiness appears only after enough consistent personal baseline data and is not a medical result.")
            metric("Unavailable", "SolarH9 shows a reason instead of filling missing or low-quality data with false precision.")
        }
        .navigationTitle("About metrics")
    }

    private func metric(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: SolarSpace.xs) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(SolarColor.textSecondary)
        }
    }
}
