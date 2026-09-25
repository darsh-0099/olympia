@preconcurrency import CoreBluetooth
import Combine
import Foundation

struct DiscoveredHeartRateDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int?
    let isKnown: Bool

    var identifierSuffix: String { String(id.uuidString.suffix(6)).uppercased() }
}

enum ConnectionRecencyQuality: String, Sendable {
    case unknown, good, stale, reconnecting
}

protocol SensorScheduler: Sendable {
    func sleep(seconds: Double) async throws
}

struct ContinuousSensorScheduler: SensorScheduler {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
final class PolarH9Client: NSObject, ObservableObject, HeartRateDataSource, @unchecked Sendable {
    private enum UUIDs {
        static let heartRateService = CBUUID(string: "180D")
        static let heartRateMeasurement = CBUUID(string: "2A37")
        static let bodySensorLocation = CBUUID(string: "2A38")
        static let batteryService = CBUUID(string: "180F")
        static let batteryLevel = CBUUID(string: "2A19")
        static let deviceInformation = CBUUID(string: "180A")
        static let modelNumber = CBUUID(string: "2A24")
        static let manufacturerName = CBUUID(string: "2A29")
    }

    private static let restorationIdentifier = "com.solarh9.central.v1"
    private static let selectedDeviceKey = "selectedPolarH9Identifier"
    private static let requestedDeviceKey = "requestedPolarH9Identifier"
    private static let shouldRunKey = "polarH9ShouldRun"

    private let stream: AsyncStream<HeartRateDataEvent>
    private let continuation: AsyncStream<HeartRateDataEvent>.Continuation
    private let clock: any SolarClock
    private let scheduler: any SensorScheduler
    private let defaults: UserDefaults
    private var central: CBCentralManager!
    private var machine = SensorConnectionMachine()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheralID: UUID?
    private var requestedDeviceID: UUID?
    private var subscribedCharacteristicIDs: Set<CBUUID> = []
    private var connectionTimeoutTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var shouldRun = false
    private var operationGeneration = 0
    private var awaitingTerminalCallback = false
    private var activeInterruptionID: UUID?
    private var lastPacketMonotonicNanoseconds: UInt64?

    @Published private(set) var state: SensorConnectionState = .disconnected
    @Published private(set) var discoveredDevices: [DiscoveredHeartRateDevice] = []
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var bodySensorLocation: String?
    @Published private(set) var modelNumber: String?
    @Published private(set) var manufacturerName: String?

    init(
        clock: any SolarClock = SystemSolarClock(),
        scheduler: any SensorScheduler = ContinuousSensorScheduler(),
        defaults: UserDefaults = .standard,
        eventBufferLimit: Int = 512
    ) {
        let pair = AsyncStream<HeartRateDataEvent>.makeStream(bufferingPolicy: .bufferingNewest(eventBufferLimit))
        stream = pair.stream
        continuation = pair.continuation
        self.clock = clock
        self.scheduler = scheduler
        self.defaults = defaults
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
    }

    deinit { continuation.finish() }

    func eventStream() async -> AsyncStream<HeartRateDataEvent> { stream }

    func start() async throws {
        if shouldRun, let id = requestedDeviceID {
            switch state {
            case .connecting(id), .connected(id), .reconnecting(id, _): return
            default: break
            }
        }
        shouldRun = true
        defaults.set(true, forKey: Self.shouldRunKey)
        operationGeneration += 1
        guard central.state == .poweredOn else { updateAvailability(); return }
        if let id = restorableDeviceID,
           let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            requestedDeviceID = id
            beginConnection(to: peripheral, resetRetry: true)
        } else if let id = restorableDeviceID {
            requestedDeviceID = id
            machine.handle(.connectRequested(id))
            publishState()
            scanForRequestedDevice()
            scheduleConnectionTimeout(for: id)
        } else {
            scan()
        }
    }

    func stop() async { stopTransport(clearSelection: false) }

    func scan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        if requestedDeviceID == nil {
            machine.handle(.scanRequested)
            publishState()
        }
        central.scanForPeripherals(withServices: [UUIDs.heartRateService])
    }

    func connect(deviceID: UUID) {
        if shouldRun, requestedDeviceID == deviceID {
            switch state {
            case .connecting(deviceID), .connected(deviceID), .reconnecting(deviceID, _): return
            default: break
            }
        }
        shouldRun = true
        defaults.set(true, forKey: Self.shouldRunKey)
        defaults.set(deviceID.uuidString, forKey: Self.requestedDeviceKey)
        operationGeneration += 1
        cancelTimers()
        let previousActive = activePeripheralID
        requestedDeviceID = deviceID
        if let previousActive, previousActive != deviceID, let peripheral = peripherals[previousActive] {
            central.cancelPeripheralConnection(peripheral)
        }
        activePeripheralID = nil
        guard central.state == .poweredOn else { updateAvailability(); return }
        if let peripheral = peripherals[deviceID] ?? central.retrievePeripherals(withIdentifiers: [deviceID]).first {
            beginConnection(to: peripheral, resetRetry: true)
        } else {
            machine.handle(.connectRequested(deviceID))
            publishState()
            scanForRequestedDevice()
            scheduleConnectionTimeout(for: deviceID)
        }
    }

    func disconnect() { stopTransport(clearSelection: false) }

    func forgetDevice() { stopTransport(clearSelection: true) }

    func connectionQuality(nowMonotonicNanoseconds: UInt64? = nil) -> ConnectionRecencyQuality {
        if case .reconnecting = state { return .reconnecting }
        guard case .connected = state, let last = lastPacketMonotonicNanoseconds else { return .unknown }
        let now = nowMonotonicNanoseconds ?? clock.monotonicNanoseconds()
        guard now >= last else { return .unknown }
        return now - last <= 3_000_000_000 ? .good : .stale
    }

    var connectedDeviceID: UUID? {
        if case .connected(let id) = state { return id }
        return nil
    }

    private var persistedDeviceID: UUID? {
        defaults.string(forKey: Self.selectedDeviceKey).flatMap(UUID.init(uuidString:))
    }

    private var restorableDeviceID: UUID? {
        defaults.string(forKey: Self.requestedDeviceKey).flatMap(UUID.init(uuidString:)) ?? persistedDeviceID
    }

    private func stopTransport(clearSelection: Bool) {
        shouldRun = false
        defaults.set(false, forKey: Self.shouldRunKey)
        operationGeneration += 1
        cancelTimers()
        central.stopScan()
        if let id = activePeripheralID, let peripheral = peripherals[id] {
            central.cancelPeripheralConnection(peripheral)
        }
        activePeripheralID = nil
        requestedDeviceID = clearSelection ? nil : restorableDeviceID
        subscribedCharacteristicIDs.removeAll()
        lastPacketMonotonicNanoseconds = nil
        endInterruptionIfNeeded()
        machine.handle(clearSelection ? .forgotDevice : .userDisconnected)
        if clearSelection { defaults.removeObject(forKey: Self.selectedDeviceKey) }
        if clearSelection { defaults.removeObject(forKey: Self.requestedDeviceKey) }
        publishState()
        refreshKnownMarkers()
    }

    private func beginConnection(to peripheral: CBPeripheral, resetRetry: Bool) {
        guard shouldRun else { return }
        if activePeripheralID == peripheral.identifier,
           (peripheral.state == .connecting || peripheral.state == .connected) {
            switch state {
            case .connecting(peripheral.identifier), .connected(peripheral.identifier): return
            default: break
            }
        }
        if resetRetry { machine.handle(.connectRequested(peripheral.identifier)) }
        requestedDeviceID = peripheral.identifier
        activePeripheralID = peripheral.identifier
        central.stopScan()
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        subscribedCharacteristicIDs.removeAll()
        awaitingTerminalCallback = false
        lastPacketMonotonicNanoseconds = nil
        publishState()
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
        scheduleConnectionTimeout(for: peripheral.identifier)
    }

    private func scanForRequestedDevice() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [UUIDs.heartRateService])
    }

    private func scheduleConnectionTimeout(for id: UUID) {
        connectionTimeoutTask?.cancel()
        let generation = operationGeneration
        connectionTimeoutTask = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(seconds: 12)
            guard !Task.isCancelled, let self, self.shouldRun, self.operationGeneration == generation,
                  self.requestedDeviceID == id, case .connecting(id) = self.state else { return }
            self.machine.handle(.timeout(id))
            self.publishState()
            if let peripheral = self.peripherals[id] {
                self.awaitingTerminalCallback = peripheral.state != .disconnected
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.scheduleRetryIfNeeded(for: id)
        }
    }

    private func scheduleRetryIfNeeded(for id: UUID) {
        guard shouldRun, case .reconnecting(id, let attempt) = state else { return }
        retryTask?.cancel()
        let generation = operationGeneration
        let delay = machine.retryPolicy.delay(forAttempt: attempt)
        retryTask = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(seconds: delay)
            guard !Task.isCancelled, let self, self.shouldRun, self.operationGeneration == generation,
                  self.requestedDeviceID == id, case .reconnecting(id, _) = self.state else { return }
            if self.awaitingTerminalCallback {
                self.scheduleRetryIfNeeded(for: id)
                return
            }
            if let peripheral = self.peripherals[id], peripheral.state != .disconnected {
                self.central.cancelPeripheralConnection(peripheral)
                self.scheduleRetryIfNeeded(for: id)
                return
            }
            self.machine.handle(.retryFired(id))
            self.publishState()
            if let peripheral = self.peripherals[id] ?? self.central.retrievePeripherals(withIdentifiers: [id]).first {
                self.beginConnection(to: peripheral, resetRetry: false)
            } else {
                self.scanForRequestedDevice()
                self.scheduleConnectionTimeout(for: id)
            }
        }
    }

    private func cancelTimers() {
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        retryTask?.cancel(); retryTask = nil
    }

    private func updateAvailability() {
        let availability: BluetoothAvailability
        switch central.state {
        case .poweredOn: availability = .poweredOn
        case .poweredOff: availability = .poweredOff
        case .unauthorized: availability = .unauthorized
        case .unsupported: availability = .unsupported
        case .resetting: availability = .resetting
        case .unknown: availability = .unknown
        @unknown default: availability = .unknown
        }
        machine.handle(.availabilityChanged(availability))
        publishState()
        guard central.state != .poweredOn else { return }
        operationGeneration += 1
        cancelTimers()
        central.stopScan()
        if let id = activePeripheralID, let peripheral = peripherals[id] {
            central.cancelPeripheralConnection(peripheral)
        }
        lastPacketMonotonicNanoseconds = nil
    }

    private func publishState() { state = machine.state }

    private func yield(_ event: HeartRateDataEvent) {
        if case .dropped = continuation.yield(event) {
            _ = continuation.yield(.dataLoss(at: clock.nowUTC(), reason: "Sensor event buffer overflow"))
        }
    }

    private func markInterruptionStarted(reason: String) {
        guard shouldRun, activeInterruptionID == nil else { return }
        let id = UUID(); activeInterruptionID = id
        yield(.interruptionStarted(id: id, at: clock.nowUTC(), reason: reason))
    }

    private func endInterruptionIfNeeded() {
        guard let id = activeInterruptionID else { return }
        yield(.interruptionEnded(id: id, at: clock.nowUTC()))
        activeInterruptionID = nil
    }

    private func refreshKnownMarkers() {
        let known = persistedDeviceID
        discoveredDevices = discoveredDevices.map {
            .init(id: $0.id, name: $0.name, rssi: $0.rssi, isKnown: $0.id == known)
        }
    }
}

extension PolarH9Client: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateAvailability()
        if central.state == .poweredOn, shouldRun || defaults.bool(forKey: Self.shouldRunKey) {
            shouldRun = true
            Task { try? await start() }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let value = RSSI.intValue == 127 ? nil : RSSI.intValue
        let item = DiscoveredHeartRateDevice(
            id: peripheral.identifier,
            name: advertisedName ?? peripheral.name ?? "Heart-rate sensor",
            rssi: value,
            isKnown: peripheral.identifier == persistedDeviceID
        )
        if let index = discoveredDevices.firstIndex(where: { $0.id == item.id }) { discoveredDevices[index] = item }
        else { discoveredDevices.append(item) }
        discoveredDevices.sort { ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min) }

        if peripheral.identifier == requestedDeviceID, shouldRun, case .connecting(peripheral.identifier) = state {
            beginConnection(to: peripheral, resetRetry: false)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard shouldRun, peripheral.identifier == requestedDeviceID,
              activePeripheralID == peripheral.identifier, case .connecting(peripheral.identifier) = state else {
            central.cancelPeripheralConnection(peripheral); return
        }
        machine.handle(.transportConnected(peripheral.identifier)); publishState()
        peripheral.delegate = self
        peripheral.discoverServices([UUIDs.heartRateService, UUIDs.batteryService, UUIDs.deviceInformation])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(peripheral, reason: error?.localizedDescription ?? "Connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(peripheral, reason: error?.localizedDescription ?? "Sensor disconnected")
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        restored.forEach { peripherals[$0.identifier] = $0; $0.delegate = self }
        guard defaults.bool(forKey: Self.shouldRunKey), let id = restorableDeviceID,
              let peripheral = peripherals[id] else { return }
        shouldRun = true
        requestedDeviceID = id
        activePeripheralID = id
        machine.handle(.connectRequested(id)); publishState()
        if peripheral.state == .connected {
            peripheral.discoverServices([UUIDs.heartRateService, UUIDs.batteryService, UUIDs.deviceInformation])
        } else if central.state == .poweredOn {
            beginConnection(to: peripheral, resetRetry: false)
        }
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, reason: String) {
        guard peripheral.identifier == requestedDeviceID, activePeripheralID == peripheral.identifier else { return }
        awaitingTerminalCallback = false
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        subscribedCharacteristicIDs.removeAll()
        lastPacketMonotonicNanoseconds = nil
        guard shouldRun else { return }
        markInterruptionStarted(reason: reason)
        if case .reconnecting(peripheral.identifier, _) = state {
            scheduleRetryIfNeeded(for: peripheral.identifier)
            return
        }
        machine.handle(.transportDisconnected(peripheral.identifier, shouldRetry: true)); publishState()
        scheduleRetryIfNeeded(for: peripheral.identifier)
    }
}

extension PolarH9Client: @preconcurrency CBPeripheralDelegate {
    private var expectedPeripheralID: UUID? { shouldRun ? requestedDeviceID : nil }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == expectedPeripheralID, error == nil else { return }
        switch state {
        case .connecting(peripheral.identifier), .connected(peripheral.identifier): break
        default: return
        }
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case UUIDs.heartRateService:
                peripheral.discoverCharacteristics([UUIDs.heartRateMeasurement, UUIDs.bodySensorLocation], for: service)
            case UUIDs.batteryService:
                peripheral.discoverCharacteristics([UUIDs.batteryLevel], for: service)
            case UUIDs.deviceInformation:
                peripheral.discoverCharacteristics([UUIDs.modelNumber, UUIDs.manufacturerName], for: service)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == expectedPeripheralID, error == nil else { return }
        switch state {
        case .connecting(peripheral.identifier), .connected(peripheral.identifier): break
        default: return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case UUIDs.heartRateMeasurement:
                guard !subscribedCharacteristicIDs.contains(characteristic.uuid) else { continue }
                subscribedCharacteristicIDs.insert(characteristic.uuid)
                if characteristic.isNotifying {
                    self.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: nil)
                } else { peripheral.setNotifyValue(true, for: characteristic) }
            case UUIDs.bodySensorLocation, UUIDs.batteryLevel, UUIDs.modelNumber, UUIDs.manufacturerName:
                peripheral.readValue(for: characteristic)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == expectedPeripheralID,
              characteristic.uuid == UUIDs.heartRateMeasurement, characteristic.isNotifying, error == nil,
              case .connecting(peripheral.identifier) = state else { return }
        cancelTimers()
        machine.handle(.subscriptionReady(peripheral.identifier)); publishState()
        defaults.set(peripheral.identifier.uuidString, forKey: Self.selectedDeviceKey)
        defaults.removeObject(forKey: Self.requestedDeviceKey)
        refreshKnownMarkers()
        endInterruptionIfNeeded()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == expectedPeripheralID, error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case UUIDs.heartRateMeasurement:
            guard case .connected(peripheral.identifier) = state else { return }
            do {
                let parsed = try HeartRateMeasurementParser.parse(data)
                let now = clock.nowUTC(), monotonic = clock.monotonicNanoseconds()
                lastPacketMonotonicNanoseconds = monotonic
                yield(.heartRate(.init(beatsPerMinute: Int(parsed.beatsPerMinute), receivedAtUTC: now,
                                      receivedMonotonicNanoseconds: monotonic, origin: .polarH9)))
                let rr = HeartRateMeasurementTimestamping.rrSamples(from: parsed, receivedAtUTC: now,
                                                                     monotonicNanoseconds: monotonic, origin: .polarH9)
                if !rr.isEmpty { yield(.rrIntervals(rr)) }
            } catch { break }
        case UUIDs.batteryLevel: batteryPercent = data.first.map(Int.init)
        case UUIDs.bodySensorLocation: bodySensorLocation = data.first.map(Self.locationName)
        case UUIDs.modelNumber: modelNumber = String(data: data, encoding: .utf8)
        case UUIDs.manufacturerName: manufacturerName = String(data: data, encoding: .utf8)
        default: break
        }
    }

    private static func locationName(_ code: UInt8) -> String {
        switch code {
        case 0: return "Other"
        case 1: return "Chest"
        case 2: return "Wrist"
        case 3: return "Finger"
        case 4: return "Hand"
        case 5: return "Ear lobe"
        case 6: return "Foot"
        default: return "Unknown"
        }
    }
}
