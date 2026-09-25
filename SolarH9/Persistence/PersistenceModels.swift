import Foundation
import SwiftData

enum SolarSchema { static let version = 1 }

struct SamplePersistenceOrder: Equatable, Sendable {
    let eventSequence: UInt64
    let withinPacketIndex: Int
}

struct ActiveSessionCandidate: Sendable {
    let draft: SessionDraft
    let sensorDeviceID: UUID?
    let lastEventSequence: UInt64
    let lastDurableEventAtUTC: Date
}

@Model final class SensorDeviceRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var lastConnectedAtUTC: Date?
    var manufacturer: String?
    var model: String?
    init(id: UUID, displayName: String, lastConnectedAtUTC: Date? = nil, manufacturer: String? = nil, model: String? = nil) {
        self.id = id; self.displayName = displayName; self.lastConnectedAtUTC = lastConnectedAtUTC
        self.manufacturer = manufacturer; self.model = model
    }
}

@Model final class HeartRateRecord {
    @Attribute(.unique) var id: UUID
    var beatsPerMinute: Int
    var receivedAtUTC: Date
    var receivedMonotonicNanoseconds: Int64
    var originRaw: String
    var eventSequence: Int64
    init(_ value: HeartRateSampleValue, eventSequence: UInt64 = 0) {
        id = value.id; beatsPerMinute = value.beatsPerMinute; receivedAtUTC = value.receivedAtUTC
        receivedMonotonicNanoseconds = Int64(clamping: value.receivedMonotonicNanoseconds); originRaw = value.origin.rawValue
        self.eventSequence = Int64(clamping: eventSequence)
    }
}

@Model final class RRIntervalRecord {
    @Attribute(.unique) var id: UUID
    var rawTicks1024: Int
    var receivedAtUTC: Date
    var receivedMonotonicNanoseconds: Int64
    var derivedBeatTimeUTC: Date?
    var derivedBeatMonotonicNanoseconds: Int64?
    var originRaw: String
    var eventSequence: Int64
    var withinPacketIndex: Int
    init(_ value: RRIntervalValue, eventSequence: UInt64 = 0, withinPacketIndex: Int = 0) {
        id = value.id; rawTicks1024 = Int(value.rawTicks1024); receivedAtUTC = value.receivedAtUTC
        receivedMonotonicNanoseconds = Int64(clamping: value.receivedMonotonicNanoseconds)
        derivedBeatTimeUTC = value.derivedBeatTimeUTC
        derivedBeatMonotonicNanoseconds = value.derivedBeatMonotonicNanoseconds.map { Int64(clamping: $0) }
        originRaw = value.origin.rawValue
        self.eventSequence = Int64(clamping: eventSequence); self.withinPacketIndex = withinPacketIndex
    }
}

@Model final class InterruptionRecord {
    @Attribute(.unique) var id: UUID
    var startedAtUTC: Date
    var endedAtUTC: Date?
    var reason: String
    init(_ value: InterruptionMarker) {
        id = value.id; startedAtUTC = value.startedAtUTC; endedAtUTC = value.endedAtUTC; reason = value.reason
    }
}

@Model final class PauseIntervalRecord {
    @Attribute(.unique) var id: UUID
    var startedAtUTC: Date
    var endedAtUTC: Date?
    init(id: UUID, startedAtUTC: Date, endedAtUTC: Date? = nil) {
        self.id = id; self.startedAtUTC = startedAtUTC; self.endedAtUTC = endedAtUTC
    }
}

@Model final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var purposeRaw: String
    var originRaw: String
    var startedAtUTC: Date
    var endedAtUTC: Date?
    var stateRaw: String
    var schemaVersion: Int
    var appVersion: String
    var timeZoneIdentifierAtStart: String
    var sensorDeviceID: UUID?
    @Relationship(deleteRule: .cascade) var heartRates: [HeartRateRecord]
    @Relationship(deleteRule: .cascade) var rrIntervals: [RRIntervalRecord]
    @Relationship(deleteRule: .cascade) var interruptions: [InterruptionRecord]
    @Relationship(deleteRule: .cascade) var pauses: [PauseIntervalRecord]

    init(_ draft: SessionDraft, sensorDeviceID: UUID? = nil,
         ordering: [UUID: SamplePersistenceOrder] = [:], appVersion: String = "0.1.0",
         timeZoneIdentifier: String = TimeZone.current.identifier) {
        id = draft.id; purposeRaw = draft.purpose.rawValue; originRaw = draft.origin.rawValue
        startedAtUTC = draft.startedAtUTC; endedAtUTC = draft.endedAtUTC; stateRaw = draft.state.rawValue
        schemaVersion = SolarSchema.version; self.appVersion = appVersion
        timeZoneIdentifierAtStart = timeZoneIdentifier
        self.sensorDeviceID = sensorDeviceID
        heartRates = draft.heartRates.map {
            HeartRateRecord($0, eventSequence: ordering[$0.id]?.eventSequence ?? $0.receivedMonotonicNanoseconds)
        }
        rrIntervals = draft.rrIntervals.enumerated().map { index, value in
            let order = ordering[value.id]
            return RRIntervalRecord(value, eventSequence: order?.eventSequence ?? value.receivedMonotonicNanoseconds,
                                    withinPacketIndex: order?.withinPacketIndex ?? index)
        }
        interruptions = draft.interruptions.map(InterruptionRecord.init)
        pauses = draft.pauses.map { PauseIntervalRecord(id: $0.id, startedAtUTC: $0.startedAtUTC, endedAtUTC: $0.endedAtUTC) }
    }
}

@Model final class SessionSummaryRecord {
    @Attribute(.unique) var sessionID: UUID
    var algorithmVersion: String
    var encodedMetrics: Data
    init(sessionID: UUID, algorithmVersion: String, encodedMetrics: Data) {
        self.sessionID = sessionID; self.algorithmVersion = algorithmVersion; self.encodedMetrics = encodedMetrics
    }
}

@Model final class DailyCheckInRecord {
    @Attribute(.unique) var id: UUID
    var dayUTC: Date
    var logicalDayKey: String
    var timeZoneIdentifier: String
    var sessionID: UUID?
    var soreness: Int?
    var stress: Int?
    var fatigue: Int?
    var mood: Int?
    var illness: Bool?
    init(id: UUID = UUID(), dayUTC: Date, logicalDayKey: String, timeZoneIdentifier: String,
         sessionID: UUID? = nil, soreness: Int? = nil,
         stress: Int? = nil, fatigue: Int? = nil, mood: Int? = nil, illness: Bool? = nil) {
        self.id = id; self.dayUTC = dayUTC; self.logicalDayKey = logicalDayKey
        self.timeZoneIdentifier = timeZoneIdentifier; self.sessionID = sessionID; self.soreness = soreness
        self.stress = stress; self.fatigue = fatigue; self.mood = mood; self.illness = illness
    }
}

@Model final class DailyMetricSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var dayUTC: Date
    var logicalDayKey: String
    var timeZoneIdentifier: String
    var sourceSessionID: UUID
    var metricID: String
    var value: Double?
    var classificationRaw: String
    var algorithmVersion: String
    var originRaw: String
    init(id: UUID = UUID(), dayUTC: Date, logicalDayKey: String, timeZoneIdentifier: String,
         sourceSessionID: UUID, metricID: String, value: Double?,
         classification: MetricClassification, algorithmVersion: String, origin: SampleOrigin) {
        self.id = id; self.dayUTC = dayUTC; self.logicalDayKey = logicalDayKey
        self.timeZoneIdentifier = timeZoneIdentifier; self.sourceSessionID = sourceSessionID; self.metricID = metricID
        self.value = value; classificationRaw = classification.rawValue; self.algorithmVersion = algorithmVersion
        originRaw = origin.rawValue
    }
}

@Model final class JournalEntryRecord {
    @Attribute(.unique) var id: UUID
    var createdAtUTC: Date
    var updatedAtUTC: Date
    var text: String
    var sessionID: UUID?
    init(id: UUID = UUID(), createdAtUTC: Date, updatedAtUTC: Date, text: String, sessionID: UUID? = nil) {
        self.id = id; self.createdAtUTC = createdAtUTC; self.updatedAtUTC = updatedAtUTC
        self.text = text; self.sessionID = sessionID
    }
}

@Model final class UserProfileRecord {
    @Attribute(.unique) var id: String
    var maximumHeartRate: Int?
    var maximumHeartRateSourceRaw: String?
    var zoneConfigurationData: Data?
    init(id: String = "current", maximumHeartRate: Int? = nil, maximumHeartRateSource: ZoneBoundarySource? = nil,
         zoneConfigurationData: Data? = nil) {
        self.id = id; self.maximumHeartRate = maximumHeartRate
        maximumHeartRateSourceRaw = maximumHeartRateSource?.rawValue; self.zoneConfigurationData = zoneConfigurationData
    }
}

@Model final class AppSettingsRecord {
    @Attribute(.unique) var id: String
    var schemaVersion: Int
    var activeSessionID: UUID?
    var activeSessionOriginRaw: String?
    init(id: String = "settings", schemaVersion: Int = SolarSchema.version, activeSessionID: UUID? = nil,
         activeSessionOrigin: SampleOrigin? = nil) {
        self.id = id; self.schemaVersion = schemaVersion; self.activeSessionID = activeSessionID
        activeSessionOriginRaw = activeSessionOrigin?.rawValue
    }
}

@Model final class ActiveRecordingRecord {
    @Attribute(.unique) var key: String
    var sessionID: UUID
    var originRaw: String
    var purposeRaw: String
    var lifecycleRaw: String
    var lastCheckpointAtUTC: Date
    var sensorDeviceID: UUID?
    var lastEventSequence: Int64
    init(sessionID: UUID, origin: SampleOrigin, purpose: MeasurementPurpose, lifecycle: SessionState,
         sensorDeviceID: UUID? = nil,
         lastCheckpointAtUTC: Date = Date(), lastEventSequence: UInt64 = 0) {
        key = "active"; self.sessionID = sessionID; originRaw = origin.rawValue; purposeRaw = purpose.rawValue
        lifecycleRaw = lifecycle.rawValue; self.lastCheckpointAtUTC = lastCheckpointAtUTC
        self.sensorDeviceID = sensorDeviceID
        self.lastEventSequence = Int64(clamping: lastEventSequence)
    }
}

enum SolarSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [
        SensorDeviceRecord.self, SessionRecord.self, HeartRateRecord.self, RRIntervalRecord.self,
        InterruptionRecord.self, PauseIntervalRecord.self, SessionSummaryRecord.self, DailyCheckInRecord.self,
        DailyMetricSnapshotRecord.self, JournalEntryRecord.self, UserProfileRecord.self, AppSettingsRecord.self,
        ActiveRecordingRecord.self
    ] }
}

enum SolarMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SolarSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum SolarPersistence {
    static func makeContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SolarSchemaV1.self)
        let configuration: ModelConfiguration
        var resolvedStoreURL: URL?
        if inMemory {
            configuration = ModelConfiguration("SolarH9-v1", schema: schema, isStoredInMemoryOnly: true)
        } else {
            let resolvedURL: URL
            if let storeURL { resolvedURL = storeURL }
            else {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true)
                    .appendingPathComponent("SolarH9", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                resolvedURL = support.appendingPathComponent("SolarH9.store")
            }
            resolvedStoreURL = resolvedURL
            configuration = ModelConfiguration("SolarH9-v1", schema: schema, url: resolvedURL)
        }
        let container = try ModelContainer(for: schema, migrationPlan: SolarMigrationPlan.self, configurations: [configuration])
        if !inMemory, let protectedURL = resolvedStoreURL {
            for url in [protectedURL, URL(fileURLWithPath: protectedURL.path + "-wal"),
                        URL(fileURLWithPath: protectedURL.path + "-shm")] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: url.path)
            }
        }
        return container
    }
}

enum SolarStoreError: Error, Equatable { case corruptRecord(UUID), unsupportedSchema(Int) }

struct JournalEntryValue: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAtUTC: Date
    let updatedAtUTC: Date
    let text: String
    let sessionID: UUID?
}

struct CheckInValue: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let dayUTC: Date
    let logicalDayKey: String
    let timeZoneIdentifier: String
    let sleepHours: Double?
    let stress: Int?
}

struct PersistedSampleOrder: Codable, Equatable, Sendable {
    let sampleID: UUID
    let eventSequence: Int64
    let withinPacketIndex: Int
}

struct PersistedSessionMetadata: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sensorDeviceID: UUID?
    let schemaVersion: Int
    let appVersion: String
    let timeZoneIdentifierAtStart: String
    let heartRateOrder: [PersistedSampleOrder]
    let rrOrder: [PersistedSampleOrder]
}

struct PersistedStoreInventory: Codable, Equatable, Sendable {
    struct Device: Codable, Equatable, Sendable { let id: UUID; let displayName: String; let lastConnectedAtUTC: Date?; let manufacturer: String?; let model: String? }
    struct Summary: Codable, Equatable, Sendable { let sessionID: UUID; let algorithmVersion: String; let encodedMetrics: Data }
    struct Snapshot: Codable, Equatable, Sendable { let id: UUID; let dayUTC: Date; let logicalDayKey: String; let timeZoneIdentifier: String; let sourceSessionID: UUID; let metricID: String; let value: Double?; let classification: String; let algorithmVersion: String; let origin: String }
    struct Profile: Codable, Equatable, Sendable { let id: String; let maximumHeartRate: Int?; let maximumHeartRateSource: String?; let zoneConfigurationData: Data? }
    struct Settings: Codable, Equatable, Sendable { let id: String; let schemaVersion: Int; let activeSessionID: UUID?; let activeSessionOrigin: String? }
    struct Active: Codable, Equatable, Sendable { let sessionID: UUID; let origin: String; let purpose: String; let lifecycle: String; let lastCheckpointAtUTC: Date; let sensorDeviceID: UUID?; let lastEventSequence: Int64 }
    let devices: [Device]
    let summaries: [Summary]
    let dailySnapshots: [Snapshot]
    let profiles: [Profile]
    let settings: [Settings]
    let activeRecordings: [Active]
}

@MainActor final class SwiftDataSessionRepository: SessionRepository, RealSessionReading {
    private let context: ModelContext
    private var knownHeartRateIDs: [UUID: Set<UUID>] = [:]
    private var knownRRIDs: [UUID: Set<UUID>] = [:]
    init(container: ModelContainer) { context = ModelContext(container) }

    func save(_ draft: SessionDraft) async throws {
        if let existing = try record(id: draft.id) { context.delete(existing) }
        context.insert(SessionRecord(draft))
        try context.save()
        knownHeartRateIDs[draft.id] = Set(draft.heartRates.map(\.id))
        knownRRIDs[draft.id] = Set(draft.rrIntervals.map(\.id))
    }

    func checkpoint(_ draft: SessionDraft, sensorDeviceID: UUID? = nil,
                    ordering: [UUID: SamplePersistenceOrder] = [:], eventSequence: UInt64 = 0) async throws {
        guard let existing = try record(id: draft.id) else {
            context.insert(SessionRecord(draft, sensorDeviceID: sensorDeviceID, ordering: ordering))
            if draft.state == .recording || draft.state == .paused {
                context.insert(ActiveRecordingRecord(sessionID: draft.id, origin: draft.origin,
                                                     purpose: draft.purpose, lifecycle: draft.state,
                                                     sensorDeviceID: sensorDeviceID, lastEventSequence: eventSequence))
            }
            try context.save(); return
        }
        guard existing.originRaw == draft.origin.rawValue, existing.purposeRaw == draft.purpose.rawValue else {
            throw SessionDraftError.sampleOriginMismatch
        }
        var heartRateIDs = knownHeartRateIDs[draft.id] ?? Set(existing.heartRates.map(\.id))
        let newHeartRates = draft.heartRates.filter { heartRateIDs.insert($0.id).inserted }
        existing.heartRates.append(contentsOf: newHeartRates.map {
            HeartRateRecord($0, eventSequence: ordering[$0.id]?.eventSequence ?? $0.receivedMonotonicNanoseconds)
        })
        var rrIDs = knownRRIDs[draft.id] ?? Set(existing.rrIntervals.map(\.id))
        existing.rrIntervals.append(contentsOf: draft.rrIntervals.enumerated().compactMap { index, value in
            guard rrIDs.insert(value.id).inserted else { return nil }
            let order = ordering[value.id]
            return RRIntervalRecord(value, eventSequence: order?.eventSequence ?? value.receivedMonotonicNanoseconds,
                                    withinPacketIndex: order?.withinPacketIndex ?? index)
        })
        existing.interruptions.forEach { context.delete($0) }
        existing.interruptions = draft.interruptions.map(InterruptionRecord.init)
        existing.pauses.forEach { context.delete($0) }
        existing.pauses = draft.pauses.map { PauseIntervalRecord(id: $0.id, startedAtUTC: $0.startedAtUTC, endedAtUTC: $0.endedAtUTC) }
        existing.stateRaw = draft.state.rawValue
        existing.endedAtUTC = draft.endedAtUTC
        if existing.sensorDeviceID == nil { existing.sensorDeviceID = sensorDeviceID }
        if draft.state == .recording || draft.state == .paused {
            if let active = try activeRecording() {
                active.sessionID = draft.id; active.originRaw = draft.origin.rawValue
                active.purposeRaw = draft.purpose.rawValue; active.lifecycleRaw = draft.state.rawValue
                active.lastCheckpointAtUTC = Date()
                active.lastEventSequence = max(active.lastEventSequence, Int64(clamping: eventSequence))
                if active.sensorDeviceID == nil { active.sensorDeviceID = sensorDeviceID }
            } else {
                context.insert(ActiveRecordingRecord(sessionID: draft.id, origin: draft.origin,
                                                     purpose: draft.purpose, lifecycle: draft.state,
                                                     sensorDeviceID: sensorDeviceID, lastEventSequence: eventSequence))
            }
        } else if let active = try activeRecording(), active.sessionID == draft.id {
            context.delete(active)
        }
        try context.save()
        knownHeartRateIDs[draft.id] = heartRateIDs
        knownRRIDs[draft.id] = rrIDs
    }

    func session(id: UUID) async throws -> SessionDraft? {
        try record(id: id).map(decode)
    }

    func sessions(scope: SessionQueryScope) async throws -> [SessionDraft] {
        let sort = [SortDescriptor<SessionRecord>(\.startedAtUTC, order: .reverse)]
        let records: [SessionRecord]
        switch scope {
        case .realOnly:
            let origin = SampleOrigin.polarH9.rawValue
            records = try context.fetch(FetchDescriptor(predicate: #Predicate<SessionRecord> { $0.originRaw == origin }, sortBy: sort))
        case .simulatedOnly:
            let origin = SampleOrigin.simulator.rawValue
            records = try context.fetch(FetchDescriptor(predicate: #Predicate<SessionRecord> { $0.originRaw == origin }, sortBy: sort))
        case .all:
            records = try context.fetch(FetchDescriptor(sortBy: sort))
        }
        return try records.map(decode)
    }

    func baselineEligibleSessions() async throws -> [SessionDraft] {
        let real = try await sessions(scope: .realOnly)
        var eligible: [SessionDraft] = []
        for draft in real where draft.passesRestingContextPrecheck &&
            (draft.endedAtUTC?.timeIntervalSince(draft.startedAtUTC) ?? 0) >= 180 && draft.heartRates.count >= 180 {
            let hrv = try HRVEngine.analyze(draft.rrIntervals, context: .restingCheckIn, configuration: .restingV1)
            if hrv.lnRMSSD.classification != .unavailable && (hrv.quality == .good || hrv.quality == .fair) {
                eligible.append(draft)
            }
        }
        return eligible
    }

    func deleteSession(id: UUID) async throws {
        if let record = try record(id: id) {
            context.delete(record)
            for summary in try context.fetch(FetchDescriptor<SessionSummaryRecord>()) where summary.sessionID == id {
                context.delete(summary)
            }
            for snapshot in try context.fetch(FetchDescriptor<DailyMetricSnapshotRecord>()) where snapshot.sourceSessionID == id {
                context.delete(snapshot)
            }
            for entry in try context.fetch(FetchDescriptor<JournalEntryRecord>()) where entry.sessionID == id {
                entry.sessionID = nil
            }
            if let active = try activeRecording(), active.sessionID == id { context.delete(active) }
            try context.save()
            knownHeartRateIDs[id] = nil; knownRRIDs[id] = nil
        }
    }

    func deleteAll() throws {
        do {
            try context.delete(model: SessionRecord.self)
            try context.delete(model: SessionSummaryRecord.self)
            try context.delete(model: DailyCheckInRecord.self)
            try context.delete(model: DailyMetricSnapshotRecord.self)
            try context.delete(model: JournalEntryRecord.self)
            try context.delete(model: ActiveRecordingRecord.self)
            try context.delete(model: SensorDeviceRecord.self)
            try context.delete(model: UserProfileRecord.self)
            try context.delete(model: AppSettingsRecord.self)
            try context.save()
            knownHeartRateIDs.removeAll(keepingCapacity: false)
            knownRRIDs.removeAll(keepingCapacity: false)
        } catch {
            context.rollback()
            throw error
        }
    }

    func saveCheckIn(sleepHours: Double, stress: Int, note: String, at now: Date = Date()) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let dayKey = formatter.string(from: now)
        let existing = try context.fetch(FetchDescriptor<DailyCheckInRecord>()).first { $0.logicalDayKey == dayKey }
        if let existing {
            existing.dayUTC = now; existing.stress = stress
        } else {
            context.insert(DailyCheckInRecord(dayUTC: now, logicalDayKey: dayKey,
                                              timeZoneIdentifier: calendar.timeZone.identifier,
                                              stress: stress))
        }
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextLine = "Sleep \(sleepHours.formatted(.number.precision(.fractionLength(1)))) h • Stress \(stress)/5"
        let journalText = cleaned.isEmpty ? contextLine : "\(contextLine)\n\(cleaned)"
        context.insert(JournalEntryRecord(createdAtUTC: now, updatedAtUTC: now, text: journalText))
        try context.save()
    }

    func journalEntries() throws -> [JournalEntryValue] {
        let records = try context.fetch(FetchDescriptor<JournalEntryRecord>(
            sortBy: [SortDescriptor(\.updatedAtUTC, order: .reverse)]
        ))
        return records.map { .init(id: $0.id, createdAtUTC: $0.createdAtUTC, updatedAtUTC: $0.updatedAtUTC,
                                   text: $0.text, sessionID: $0.sessionID) }
    }

    func checkIns() throws -> [CheckInValue] {
        try context.fetch(FetchDescriptor<DailyCheckInRecord>(
            sortBy: [SortDescriptor(\.dayUTC, order: .reverse)]
        )).map { .init(id: $0.id, dayUTC: $0.dayUTC, logicalDayKey: $0.logicalDayKey,
                      timeZoneIdentifier: $0.timeZoneIdentifier, sleepHours: nil, stress: $0.stress) }
    }

    func exportMetadata() throws -> [PersistedSessionMetadata] {
        try context.fetch(FetchDescriptor<SessionRecord>()).map { session in
            .init(sessionID: session.id, sensorDeviceID: session.sensorDeviceID,
                  schemaVersion: session.schemaVersion, appVersion: session.appVersion,
                  timeZoneIdentifierAtStart: session.timeZoneIdentifierAtStart,
                  heartRateOrder: session.heartRates.map {
                    .init(sampleID: $0.id, eventSequence: $0.eventSequence, withinPacketIndex: 0)
                  }.sorted { $0.eventSequence == $1.eventSequence ? $0.sampleID.uuidString < $1.sampleID.uuidString : $0.eventSequence < $1.eventSequence },
                  rrOrder: session.rrIntervals.map {
                    .init(sampleID: $0.id, eventSequence: $0.eventSequence, withinPacketIndex: $0.withinPacketIndex)
                  }.sorted {
                    if $0.eventSequence != $1.eventSequence { return $0.eventSequence < $1.eventSequence }
                    if $0.withinPacketIndex != $1.withinPacketIndex { return $0.withinPacketIndex < $1.withinPacketIndex }
                    return $0.sampleID.uuidString < $1.sampleID.uuidString
                  })
        }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    func exportInventory() throws -> PersistedStoreInventory {
        .init(
            devices: try context.fetch(FetchDescriptor<SensorDeviceRecord>()).map {
                .init(id: $0.id, displayName: $0.displayName, lastConnectedAtUTC: $0.lastConnectedAtUTC,
                      manufacturer: $0.manufacturer, model: $0.model)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            summaries: try context.fetch(FetchDescriptor<SessionSummaryRecord>()).map {
                .init(sessionID: $0.sessionID, algorithmVersion: $0.algorithmVersion, encodedMetrics: $0.encodedMetrics)
            }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString },
            dailySnapshots: try context.fetch(FetchDescriptor<DailyMetricSnapshotRecord>()).map {
                .init(id: $0.id, dayUTC: $0.dayUTC, logicalDayKey: $0.logicalDayKey,
                      timeZoneIdentifier: $0.timeZoneIdentifier, sourceSessionID: $0.sourceSessionID,
                      metricID: $0.metricID, value: $0.value, classification: $0.classificationRaw,
                      algorithmVersion: $0.algorithmVersion, origin: $0.originRaw)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            profiles: try context.fetch(FetchDescriptor<UserProfileRecord>()).map {
                .init(id: $0.id, maximumHeartRate: $0.maximumHeartRate,
                      maximumHeartRateSource: $0.maximumHeartRateSourceRaw,
                      zoneConfigurationData: $0.zoneConfigurationData)
            }.sorted { $0.id < $1.id },
            settings: try context.fetch(FetchDescriptor<AppSettingsRecord>()).map {
                .init(id: $0.id, schemaVersion: $0.schemaVersion, activeSessionID: $0.activeSessionID,
                      activeSessionOrigin: $0.activeSessionOriginRaw)
            }.sorted { $0.id < $1.id },
            activeRecordings: try context.fetch(FetchDescriptor<ActiveRecordingRecord>()).map {
                .init(sessionID: $0.sessionID, origin: $0.originRaw, purpose: $0.purposeRaw,
                      lifecycle: $0.lifecycleRaw, lastCheckpointAtUTC: $0.lastCheckpointAtUTC,
                      sensorDeviceID: $0.sensorDeviceID, lastEventSequence: $0.lastEventSequence)
            }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
        )
    }

    func salvageIncompleteSessions(at nowUTC: Date) async throws -> [UUID] {
        let drafts = try await sessions(scope: .all)
        var salvaged: [UUID] = []
        for var draft in drafts where draft.state == .recording || draft.state == .paused {
            if draft.state == .paused, let openPause = draft.pauses.last(where: { $0.endedAtUTC == nil }) {
                try draft.endPause(id: openPause.id, at: max(nowUTC, openPause.startedAtUTC))
            }
            for marker in draft.interruptions where marker.endedAtUTC == nil {
                try draft.endInterruption(id: marker.id, at: nowUTC)
            }
            let marker = InterruptionMarker(startedAtUTC: nowUTC, endedAtUTC: nowUTC,
                                            reason: "Recording ended unexpectedly before relaunch")
            try draft.markInterrupted(at: nowUTC, marker: marker)
            try await checkpoint(draft); salvaged.append(draft.id)
        }
        return salvaged
    }

    func activeSessionCandidate() throws -> ActiveSessionCandidate? {
        guard let active = try activeRecording() else { return nil }
        return try record(id: active.sessionID).map { record in
            let lastSampleAt = (record.heartRates.map(\.receivedAtUTC) + record.rrIntervals.map(\.receivedAtUTC)).max()
            return ActiveSessionCandidate(draft: try decode(record), sensorDeviceID: active.sensorDeviceID,
                lastEventSequence: active.lastEventSequence >= 0 ? UInt64(active.lastEventSequence) : 0,
                lastDurableEventAtUTC: max(record.startedAtUTC, lastSampleAt ?? active.lastCheckpointAtUTC))
        }
    }

    private func record(id: UUID) throws -> SessionRecord? {
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func activeRecording() throws -> ActiveRecordingRecord? {
        var descriptor = FetchDescriptor<ActiveRecordingRecord>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func decode(_ record: SessionRecord) throws -> SessionDraft {
        guard record.schemaVersion == SolarSchema.version else { throw SolarStoreError.unsupportedSchema(record.schemaVersion) }
        guard let purpose = MeasurementPurpose(rawValue: record.purposeRaw),
              let origin = SampleOrigin(rawValue: record.originRaw),
              let state = SessionState(rawValue: record.stateRaw) else { throw SolarStoreError.corruptRecord(record.id) }
        let orderedHeartRates = record.heartRates.sorted {
            if $0.eventSequence != $1.eventSequence { return $0.eventSequence < $1.eventSequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        let heartRates = try orderedHeartRates.map { value -> HeartRateSampleValue in
            guard let itemOrigin = SampleOrigin(rawValue: value.originRaw), value.receivedMonotonicNanoseconds >= 0 else {
                throw SolarStoreError.corruptRecord(record.id)
            }
            return .init(id: value.id, beatsPerMinute: value.beatsPerMinute, receivedAtUTC: value.receivedAtUTC,
                         receivedMonotonicNanoseconds: UInt64(value.receivedMonotonicNanoseconds), origin: itemOrigin)
        }
        let orderedRR = record.rrIntervals.sorted {
            if $0.eventSequence != $1.eventSequence { return $0.eventSequence < $1.eventSequence }
            if $0.withinPacketIndex != $1.withinPacketIndex { return $0.withinPacketIndex < $1.withinPacketIndex }
            return $0.id.uuidString < $1.id.uuidString
        }
        let rr = try orderedRR.map { value -> RRIntervalValue in
            guard let itemOrigin = SampleOrigin(rawValue: value.originRaw),
                  let raw = UInt16(exactly: value.rawTicks1024), value.receivedMonotonicNanoseconds >= 0,
                  value.derivedBeatMonotonicNanoseconds.map({ $0 >= 0 }) ?? true else {
                throw SolarStoreError.corruptRecord(record.id)
            }
            return .init(id: value.id, rawTicks1024: raw, receivedAtUTC: value.receivedAtUTC,
                         receivedMonotonicNanoseconds: UInt64(value.receivedMonotonicNanoseconds),
                         derivedBeatTimeUTC: value.derivedBeatTimeUTC,
                         derivedBeatMonotonicNanoseconds: value.derivedBeatMonotonicNanoseconds.map { UInt64($0) }, origin: itemOrigin)
        }
        let interruptions = record.interruptions.map {
            InterruptionMarker(id: $0.id, startedAtUTC: $0.startedAtUTC, endedAtUTC: $0.endedAtUTC, reason: $0.reason)
        }.sorted { $0.startedAtUTC < $1.startedAtUTC }
        let pauses = record.pauses.map {
            PauseIntervalValue(id: $0.id, startedAtUTC: $0.startedAtUTC, endedAtUTC: $0.endedAtUTC)
        }.sorted { $0.startedAtUTC < $1.startedAtUTC }
        return try SessionDraft(id: record.id, purpose: purpose, origin: origin, startedAtUTC: record.startedAtUTC,
                                endedAtUTC: record.endedAtUTC, state: state, heartRates: heartRates,
                                rrIntervals: rr, interruptions: interruptions, pauses: pauses)
    }
}
