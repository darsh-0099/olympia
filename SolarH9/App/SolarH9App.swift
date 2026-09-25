import SwiftUI

@main
@MainActor
struct SolarH9App: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appModel = AppModel()
    @StateObject private var coordinator: SensorCoordinator
    @StateObject private var productStore: ProductStore
    @StateObject private var themeStore: SolarThemeStore
    private let trainingStore: OlympiaTrainingStore?
    private let trainingError: String?

    init() {
        let sensor = PolarH9Client()
        _themeStore = StateObject(wrappedValue: SolarThemeStore())
        do {
            trainingStore = try OlympiaTrainingStore()
            trainingError = nil
        } catch {
            trainingStore = nil
            trainingError = error.localizedDescription
        }
        do {
            let container = try SolarPersistence.makeContainer()
            let repository = SwiftDataSessionRepository(container: container)
            let recording = RecordingController(repository: repository)
            _coordinator = StateObject(wrappedValue: SensorCoordinator(sensor: sensor, recording: recording))
            _productStore = StateObject(wrappedValue: ProductStore(repository: repository))
        } catch {
            _coordinator = StateObject(wrappedValue: SensorCoordinator(
                sensor: sensor,
                persistenceError: "SolarH9 could not open its local data store. Your store was not reset. \(error.localizedDescription)"
            ))
            _productStore = StateObject(wrappedValue: ProductStore(repository: nil))
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let persistenceError = coordinator.persistenceError {
                    ContentUnavailableView("Local data unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(persistenceError))
                        .padding()
                } else if let trainingStore {
                    OlympiaRootView(store: trainingStore)
                } else {
                    ContentUnavailableView("Training data unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(trainingError ?? "The local database could not open."))
                }
            }
            .environment(appModel)
            .environmentObject(coordinator)
            .environmentObject(productStore)
            .environmentObject(themeStore)
            .environment(\.solarTheme, SolarThemePalette(themeStore.applied))
            .preferredColorScheme(themeStore.preferredColorScheme)
            .tint(SolarThemePalette(themeStore.applied).accent)
            .task(id: appModel.sourceSelection) {
                await coordinator.activate()
                await coordinator.select(appModel.sourceSelection)
                productStore.configureMaximumHeartRate(appModel.maximumHeartRate == 0 ? nil : appModel.maximumHeartRate)
                coordinator.configureMaximumHeartRate(appModel.maximumHeartRate == 0 ? nil : appModel.maximumHeartRate)
                coordinator.configureReducedAnimation(themeStore.applied.reducedAnimation)
                if coordinator.hasActiveRecording, appModel.sourceSelection != coordinator.selectedSource {
                    appModel.sourceSelection = coordinator.selectedSource
                }
                await productStore.refresh()
            }
            .onChange(of: appModel.maximumHeartRate) { _, value in
                let maximum = value == 0 ? nil : value
                productStore.configureMaximumHeartRate(maximum)
                coordinator.configureMaximumHeartRate(maximum)
            }
            .onChange(of: themeStore.applied) { _, preferences in
                coordinator.configureReducedAnimation(preferences.reducedAnimation)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await coordinator.flushForBackground() } }
            }
        }
    }
}
