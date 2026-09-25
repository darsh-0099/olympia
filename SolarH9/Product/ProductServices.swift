import Foundation
import Combine

struct SessionOverview: Identifiable, Equatable, Sendable {
    let id: UUID
    let session: SessionDraft
    let averageHeartRate: MetricResult
    let rmssd: MetricResult
    let trainingLoad: MetricResult
    let recovery: MetricResult
    let secondsByZone: [Int: Double]

    var durationSeconds: Double {
        max(0, (session.endedAtUTC ?? Date()).timeIntervalSince(session.startedAtUTC))
    }
}

struct RuntimePreferencesExport: Codable, Equatable, Sendable {
    let maximumHeartRate: Int?
    let sourceSelection: String?
    let sleepHoursByLogicalDay: [String: Double]
}

@MainActor
final class ProductStore: ObservableObject {
    @Published private(set) var realSessions: [SessionOverview] = []
    @Published private(set) var allSessions: [SessionDraft] = []
    @Published private(set) var journalEntries: [JournalEntryValue] = []
    @Published private(set) var checkIns: [CheckInValue] = []
    @Published private(set) var baselineEligibleSessionIDs: Set<UUID> = []
    @Published private(set) var readiness: ReadinessEstimate?
    @Published private(set) var persistedMetadata: [PersistedSessionMetadata] = []
    @Published private(set) var persistedInventory: PersistedStoreInventory?
    @Published private(set) var exportFiles: [URL] = []
    @Published private(set) var errorMessage: String?

    private let repository: SwiftDataSessionRepository?
    private var maximumHeartRate: Int?
    private let diagnostics = SanitizedDiagnostics()
    private let defaults: UserDefaults

    init(repository: SwiftDataSessionRepository?, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        Self.removeStaleExports()
        Task { [diagnostics] in await diagnostics.record(.appLaunched) }
    }

    func configureMaximumHeartRate(_ value: Int?) {
        maximumHeartRate = value.flatMap { $0 >= 100 ? $0 : nil }
    }

    func refresh() async {
        do {
            guard let repository else { return }
            let real = try await repository.sessions(scope: .realOnly)
            allSessions = try await repository.sessions(scope: .all)
            let eligible = try await repository.baselineEligibleSessions()
            baselineEligibleSessionIDs = Set(eligible.map(\.id))
            realSessions = real.filter { $0.state == .completed || $0.state == .interrupted }
                .compactMap { Self.makeOverview($0, maximumHeartRate: maximumHeartRate) }
            journalEntries = try repository.journalEntries()
            let sleepByDay = Self.sleepHoursByDay(defaults)
            checkIns = try repository.checkIns().map {
                .init(id: $0.id, dayUTC: $0.dayUTC, logicalDayKey: $0.logicalDayKey,
                      timeZoneIdentifier: $0.timeZoneIdentifier,
                      sleepHours: sleepByDay[$0.logicalDayKey], stress: $0.stress)
            }
            persistedMetadata = try repository.exportMetadata()
            persistedInventory = try repository.exportInventory()
            readiness = try Self.makeReadiness(from: eligible)
            errorMessage = nil
            await diagnostics.record(.persistenceOpened)
        } catch {
            await diagnostics.record(.persistenceOpenFailed, severity: .error)
            errorMessage = "Could not load local data: \(error.localizedDescription)"
        }
    }

    func saveCheckIn(sleepHours: Double, stress: Int, note: String) async -> Bool {
        do {
            guard let repository else { return false }
            try repository.saveCheckIn(sleepHours: sleepHours, stress: stress, note: note)
            var values = Self.sleepHoursByDay(defaults)
            values[Self.logicalDayKey(Date())] = sleepHours
            defaults.set(values, forKey: "structuredSleepHoursByDay")
            await refresh(); return true
        } catch { errorMessage = "Could not save this check-in: \(error.localizedDescription)"; return false }
    }

    func deleteSession(id: UUID) async -> Bool {
        guard let repository else { return false }
        do { try await repository.deleteSession(id: id); await refresh(); return true }
        catch { await diagnostics.record(.deletionFailed, severity: .error); errorMessage = "Could not delete the session: \(error.localizedDescription)"; return false }
    }

    func deleteAll() async -> Bool {
        do {
            guard let repository else { return false }
            try repository.deleteAll()
            defaults.removeObject(forKey: "structuredSleepHoursByDay")
            defaults.removeObject(forKey: "maximumHeartRate")
            cleanupExports()
            await diagnostics.removeAll()
            realSessions = []; allSessions = []; journalEntries = []; checkIns = []
            baselineEligibleSessionIDs = []; readiness = nil; persistedMetadata = []; persistedInventory = nil; errorMessage = nil
            return true
        } catch { await diagnostics.record(.deletionFailed, severity: .error); errorMessage = "Could not delete local data: \(error.localizedDescription)"; return false }
    }

    func prepareExport(sessionID: UUID? = nil) async {
        do {
            cleanupExports()
            let sessions = sessionID.map { id in allSessions.filter { $0.id == id } } ?? allSessions
            exportFiles = try LocalArchiveExporter.export(sessions: sessions,
                checkIns: sessionID == nil ? checkIns : [],
                journalEntries: sessionID == nil ? journalEntries : journalEntries.filter { $0.sessionID == sessionID },
                metadata: persistedMetadata.filter { sessionID == nil || $0.sessionID == sessionID },
                inventory: sessionID == nil ? persistedInventory : nil,
                runtimePreferences: sessionID == nil ? .init(
                    maximumHeartRate: defaults.integer(forKey: "maximumHeartRate").nonzero,
                    sourceSelection: defaults.string(forKey: "sourceSelection"),
                    sleepHoursByLogicalDay: Self.sleepHoursByDay(defaults)) : nil)
            errorMessage = nil
            await diagnostics.record(.exportCreated)
        } catch { await diagnostics.record(.exportFailed, severity: .error); errorMessage = "Could not create the export: \(error.localizedDescription)" }
    }

    func prepareDiagnostics() async {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SolarH9-Export-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            let url = directory.appendingPathComponent("sanitized-diagnostics.json")
            try await diagnostics.writeProtected(to: url)
            exportFiles.append(url)
        } catch { errorMessage = "Could not create sanitized diagnostics: \(error.localizedDescription)" }
    }

    func cleanupExports() {
        for directory in Set(exportFiles.map { $0.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: directory)
        }
        exportFiles = []
    }

    static func makeOverview(_ session: SessionDraft, maximumHeartRate: Int? = nil) -> SessionOverview? {
        let lineage = MetricLineage(sampleOrigins: [session.origin])
        let averageValue = session.heartRates.isEmpty ? nil :
            Double(session.heartRates.map(\.beatsPerMinute).reduce(0, +)) / Double(session.heartRates.count)
        let average = try? MetricResult(id: "average_hr", name: "Average HR", value: averageValue, unit: "bpm",
            classification: averageValue == nil ? .unavailable : .calculated, context: session.purpose,
            lineage: averageValue == nil ? .init(sampleOrigins: []) : lineage,
            algorithmVersion: "average-hr-v1", configurationVersion: "average-hr-v1",
            quality: averageValue == nil ? .insufficient : (session.interruptions.isEmpty ? .good : .fair),
            reasons: averageValue == nil ? ["No heart-rate samples were recorded"] :
                (session.interruptions.isEmpty ? [] : ["The session contains an interruption"]))
        let hrv = try? HRVEngine.analyze(session.rrIntervals, context: session.purpose,
                                         configuration: session.purpose == .restingCheckIn ? .restingV1 : .sessionV1)
        let unavailableLoad = try? MetricResult(id: "edwards_trimp", name: "Cardiovascular load", value: nil,
            unit: "AU", classification: .unavailable, context: .exerciseSession,
            lineage: .init(sampleOrigins: []), algorithmVersion: "edwards-trimp-v1",
            configurationVersion: "zones-v1", quality: .insufficient,
            reasons: ["Set a measured or estimated maximum heart rate to calculate load"])
        let calculatedLoad: ZoneLoadResult? = {
            guard session.purpose == .exerciseSession, let maximumHeartRate,
                  !session.heartRates.isEmpty,
                  let result = try? TrainingLoadEngine.calculate(segments: trainingSegments(for: session), zones: .standard(
                    maximumHeartRate: maximumHeartRate, source: .measured, effectiveAtUTC: session.startedAtUTC)) else { return nil }
            return result
        }()
        let recovery = try? MetricResult(id: "heart_rate_recovery_1m", name: "One-minute recovery", value: nil,
            unit: "bpm", classification: .unavailable, context: .exerciseSession,
            lineage: .init(sampleOrigins: []), algorithmVersion: "recovery-v1",
            configurationVersion: "standing-60s-v1", quality: .insufficient,
            reasons: ["A continuous one-minute post-exercise recovery protocol was not recorded"])
        guard let average, let rmssd = hrv?.rmssdMilliseconds,
              let trainingLoad = calculatedLoad?.edwardsTRIMP ?? unavailableLoad, let recovery else { return nil }
        return .init(id: session.id, session: session, averageHeartRate: average,
                     rmssd: rmssd, trainingLoad: trainingLoad, recovery: recovery,
                     secondsByZone: calculatedLoad?.secondsByZone ?? [:])
    }

    static func makeReadiness(from sessions: [SessionDraft]) throws -> ReadinessEstimate? {
        let ordered = sessions.sorted { $0.startedAtUTC > $1.startedAtUTC }
        guard let todaySession = ordered.first,
              Calendar.current.isDateInToday(todaySession.startedAtUTC),
              let todayOverview = makeOverview(todaySession),
              let todayHR = todayOverview.averageHeartRate.value,
              let todayAnalysis = try? HRVEngine.analyze(todaySession.rrIntervals, context: .restingCheckIn,
                                                         configuration: .restingV1),
              let todayLnRMSSD = todayAnalysis.lnRMSSD.value else { return nil }
        let today = ReadinessInput(dayUTC: todaySession.startedAtUTC, restingHeartRate: todayHR,
                                   lnRMSSD: todayLnRMSSD, origin: todaySession.origin,
                                   purpose: todaySession.purpose, state: todaySession.state,
                                   durationSeconds: todayOverview.durationSeconds,
                                   interruptionCount: todaySession.interruptions.count, quality: todayAnalysis.quality)
        let baseline = ordered.dropFirst().compactMap { session -> ReadinessInput? in
            guard let overview = makeOverview(session), let hr = overview.averageHeartRate.value,
                  let analysis = try? HRVEngine.analyze(session.rrIntervals, context: .restingCheckIn,
                                                        configuration: .restingV1),
                  let lnr = analysis.lnRMSSD.value else { return nil }
            return .init(dayUTC: session.startedAtUTC, restingHeartRate: hr, lnRMSSD: lnr,
                         origin: session.origin, purpose: session.purpose, state: session.state,
                         durationSeconds: overview.durationSeconds, interruptionCount: session.interruptions.count,
                         quality: analysis.quality)
        }
        return try ReadinessEngine.estimate(today: today, baseline: baseline)
    }

    static func trainingSegments(for session: SessionDraft) -> [ActiveHeartRateSegment] {
        let ordered = session.heartRates.sorted { $0.receivedMonotonicNanoseconds < $1.receivedMonotonicNanoseconds }
        let blocked: [(Date, Date)] = session.pauses.compactMap { pause in
            pause.endedAtUTC.map { (pause.startedAtUTC, $0) }
        } + session.interruptions.compactMap { marker in
            marker.endedAtUTC.map { (marker.startedAtUTC, $0) }
        }
        let usable = ordered.filter { sample in
            !blocked.contains { sample.receivedAtUTC >= $0.0 && sample.receivedAtUTC <= $0.1 }
        }
        var groups: [[HeartRateSampleValue]] = []
        for sample in usable {
            guard let previous = groups.last?.last else { groups.append([sample]); continue }
            let monotonicGap = sample.receivedMonotonicNanoseconds >= previous.receivedMonotonicNanoseconds
                ? sample.receivedMonotonicNanoseconds - previous.receivedMonotonicNanoseconds : UInt64.max
            let crossesBlocked = blocked.contains { $0.0 < sample.receivedAtUTC && $0.1 > previous.receivedAtUTC }
            if monotonicGap > 5_000_000_000 || crossesBlocked { groups.append([sample]) }
            else { groups[groups.count - 1].append(sample) }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last,
                  last.receivedMonotonicNanoseconds > first.receivedMonotonicNanoseconds else { return nil }
            return try? ActiveHeartRateSegment(samples: group,
                startMonotonicNanoseconds: first.receivedMonotonicNanoseconds,
                endMonotonicNanoseconds: last.receivedMonotonicNanoseconds)
        }
    }

    private static func removeStaleExports() {
        let temporary = FileManager.default.temporaryDirectory
        guard let children = try? FileManager.default.contentsOfDirectory(at: temporary,
            includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.hasPrefix("SolarH9-Export-") {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func logicalDayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = .init(identifier: .gregorian)
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sleepHoursByDay(_ defaults: UserDefaults) -> [String: Double] {
        let raw = defaults.dictionary(forKey: "structuredSleepHoursByDay") ?? [:]
        return raw.reduce(into: [:]) { result, pair in
            if let value = pair.value as? NSNumber { result[pair.key] = value.doubleValue }
        }
    }
}

private extension Int { var nonzero: Int? { self == 0 ? nil : self } }

enum LocalArchiveExporter {
    private struct Manifest: Encodable {
        let archiveVersion = "solarh9-export-v1"
        let generatedAtUTC: Date
        let appVersion = "0.1.0"
        let sessions: [SessionDraft]
        let checkIns: [CheckInValue]
        let journalEntries: [JournalEntryValue]
        let persistedMetadata: [PersistedSessionMetadata]
        let persistedInventory: PersistedStoreInventory?
        let runtimePreferences: RuntimePreferencesExport?
    }

    static func export(sessions: [SessionDraft], checkIns: [CheckInValue],
                       journalEntries: [JournalEntryValue], metadata: [PersistedSessionMetadata] = [],
                       inventory: PersistedStoreInventory? = nil,
                       runtimePreferences: RuntimePreferencesExport? = nil,
                       generatedAtUTC: Date = Date()) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SolarH9-Export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let csvURL = directory.appendingPathComponent("samples.csv")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Manifest(generatedAtUTC: generatedAtUTC,
                                    sessions: sessions.sorted { $0.id.uuidString < $1.id.uuidString },
                                    checkIns: checkIns.sorted { $0.id.uuidString < $1.id.uuidString },
                                    journalEntries: journalEntries.sorted { $0.id.uuidString < $1.id.uuidString },
                                    persistedMetadata: metadata.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString },
                                    persistedInventory: inventory, runtimePreferences: runtimePreferences))
            .write(to: manifestURL, options: [.atomic, .completeFileProtection])
        var rows = ["session_id,session_origin,purpose,sample_id,sample_type,received_at_utc,monotonic_nanoseconds,event_sequence,within_packet_index,bpm,raw_rr_ticks_1024,rr_milliseconds"]
        let iso = ISO8601DateFormatter()
        let order = Dictionary(uniqueKeysWithValues: metadata.flatMap { item in
            (item.heartRateOrder + item.rrOrder).map { ($0.sampleID, $0) }
        })
        for session in sessions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let heartRates = session.heartRates.sorted(by: { (left: HeartRateSampleValue, right: HeartRateSampleValue) in
                let lhs = order[left.id], rhs = order[right.id]
                if lhs?.eventSequence != rhs?.eventSequence {
                    return (lhs?.eventSequence ?? Int64.max) < (rhs?.eventSequence ?? Int64.max)
                }
                if left.receivedMonotonicNanoseconds != right.receivedMonotonicNanoseconds {
                    return left.receivedMonotonicNanoseconds < right.receivedMonotonicNanoseconds
                }
                return left.id.uuidString < right.id.uuidString
            })
            for sample in heartRates {
                let persisted = order[sample.id]
                rows.append([session.id.uuidString, session.origin.rawValue, session.purpose.rawValue, sample.id.uuidString, "heart_rate",
                             iso.string(from: sample.receivedAtUTC), String(sample.receivedMonotonicNanoseconds),
                             persisted.map { String($0.eventSequence) } ?? "", "0",
                             String(sample.beatsPerMinute), "", ""].map(csv).joined(separator: ","))
            }
            let rrIntervals = session.rrIntervals.sorted(by: { (left: RRIntervalValue, right: RRIntervalValue) in
                let lhs = order[left.id], rhs = order[right.id]
                if lhs?.eventSequence != rhs?.eventSequence {
                    return (lhs?.eventSequence ?? Int64.max) < (rhs?.eventSequence ?? Int64.max)
                }
                if lhs?.withinPacketIndex != rhs?.withinPacketIndex {
                    return (lhs?.withinPacketIndex ?? Int.max) < (rhs?.withinPacketIndex ?? Int.max)
                }
                if left.receivedMonotonicNanoseconds != right.receivedMonotonicNanoseconds {
                    return left.receivedMonotonicNanoseconds < right.receivedMonotonicNanoseconds
                }
                return left.id.uuidString < right.id.uuidString
            })
            for sample in rrIntervals {
                let persisted = order[sample.id]
                rows.append([session.id.uuidString, session.origin.rawValue, session.purpose.rawValue, sample.id.uuidString, "rr_interval",
                             iso.string(from: sample.receivedAtUTC), String(sample.receivedMonotonicNanoseconds),
                             persisted.map { String($0.eventSequence) } ?? "",
                             persisted.map { String($0.withinPacketIndex) } ?? "", "",
                             String(sample.rawTicks1024), String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), sample.milliseconds)]
                    .map(csv).joined(separator: ","))
            }
        }
        try rows.joined(separator: "\n").appending("\n").write(to: csvURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: csvURL.path)
        return [manifestURL, csvURL]
    }

    private static func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
