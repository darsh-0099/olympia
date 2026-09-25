import Foundation

enum BluetoothAvailability: Equatable, Sendable {
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
    case unknown
}

enum SensorConnectionState: Equatable, Sendable {
    case bluetoothUnavailable
    case unauthorized
    case scanning
    case connecting(UUID)
    case connected(UUID)
    case reconnecting(UUID, attempt: Int)
    case disconnected
    case error(String)
}

enum SensorConnectionEvent: Equatable, Sendable {
    case availabilityChanged(BluetoothAvailability)
    case scanRequested
    case connectRequested(UUID)
    case transportConnected(UUID)
    case subscriptionReady(UUID)
    case transportDisconnected(UUID, shouldRetry: Bool)
    case timeout(UUID)
    case retryFired(UUID)
    case userDisconnected
    case forgotDevice
}

struct RetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let initialDelaySeconds: Double
    let maximumDelaySeconds: Double

    static let standard = RetryPolicy(maximumAttempts: 5, initialDelaySeconds: 1, maximumDelaySeconds: 16)

    func delay(forAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return 0 }
        return min(initialDelaySeconds * pow(2, Double(attempt - 1)), maximumDelaySeconds)
    }
}

struct SensorConnectionMachine: Equatable, Sendable {
    private(set) var state: SensorConnectionState = .disconnected
    private(set) var selectedDeviceID: UUID?
    private(set) var retryAttempt = 0
    let retryPolicy: RetryPolicy

    init(retryPolicy: RetryPolicy = .standard) {
        self.retryPolicy = retryPolicy
    }

    mutating func handle(_ event: SensorConnectionEvent) {
        switch event {
        case .availabilityChanged(.poweredOn):
            if state == .bluetoothUnavailable || state == .unauthorized { state = .disconnected }
        case .availabilityChanged(.unauthorized):
            retryAttempt = 0
            state = .unauthorized
        case .availabilityChanged:
            retryAttempt = 0
            state = .bluetoothUnavailable
        case .scanRequested:
            guard state != .unauthorized && state != .bluetoothUnavailable else { return }
            state = .scanning
        case .connectRequested(let id):
            selectedDeviceID = id
            retryAttempt = 0
            state = .connecting(id)
        case .transportConnected(let id):
            guard selectedDeviceID == id, case .connecting(id) = state else { return }
            state = .connecting(id)
        case .subscriptionReady(let id):
            guard selectedDeviceID == id, case .connecting(id) = state else { return }
            retryAttempt = 0
            state = .connected(id)
        case .transportDisconnected(let id, let shouldRetry):
            guard selectedDeviceID == id else { return }
            switch state {
            case .connecting(id), .connected(id): break
            case .reconnecting(id, _):
                if shouldRetry { return }
            default: return
            }
            guard shouldRetry else {
                retryAttempt = 0
                state = .disconnected
                return
            }
            beginReconnect(id: id)
        case .timeout(let id):
            guard selectedDeviceID == id, case .connecting(id) = state else { return }
            beginReconnect(id: id)
        case .retryFired(let id):
            guard selectedDeviceID == id,
                  case .reconnecting(id, _) = state else { return }
            state = .connecting(id)
        case .userDisconnected:
            retryAttempt = 0
            state = .disconnected
        case .forgotDevice:
            retryAttempt = 0
            selectedDeviceID = nil
            state = .disconnected
        }
    }

    private mutating func beginReconnect(id: UUID) {
            guard retryAttempt < retryPolicy.maximumAttempts else {
                state = .error("Unable to reconnect after \(retryPolicy.maximumAttempts) attempts.")
                return
            }
            retryAttempt += 1
            state = .reconnecting(id, attempt: retryAttempt)
    }
}
