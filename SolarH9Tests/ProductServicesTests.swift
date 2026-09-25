import XCTest
@testable import SolarH9

@MainActor
final class ProductServicesTests: XCTestCase {
    func testOverviewPreservesUnavailableMetricsInsteadOfInventingValues() throws {
        let start = Date(timeIntervalSince1970: 100)
        var draft = try SessionDraft(purpose: .exerciseSession, origin: .polarH9, startedAtUTC: start)
        try draft.append(HeartRateSampleValue(beatsPerMinute: 72, receivedAtUTC: start,
                                              receivedMonotonicNanoseconds: 1, origin: .polarH9))
        try draft.complete(at: start.addingTimeInterval(60))
        let overview = try XCTUnwrap(ProductStore.makeOverview(draft))
        XCTAssertEqual(overview.averageHeartRate.value, 72)
        XCTAssertEqual(overview.rmssd.classification, .unavailable)
        XCTAssertEqual(overview.trainingLoad.classification, .unavailable)
    }

    func testExportContainsRawTicksProvenanceAndEscapedJournal() throws {
        let start = Date(timeIntervalSince1970: 100)
        var draft = try SessionDraft(purpose: .restingCheckIn, origin: .simulator, startedAtUTC: start)
        try draft.append(RRIntervalValue(rawTicks1024: 1_025, receivedAtUTC: start,
                                         receivedMonotonicNanoseconds: 7, derivedBeatTimeUTC: nil,
                                         derivedBeatMonotonicNanoseconds: nil, origin: .simulator))
        try draft.complete(at: start.addingTimeInterval(1))
        let journal = JournalEntryValue(id: UUID(), createdAtUTC: start, updatedAtUTC: start,
                                        text: "line one, \"quoted\"\nline two", sessionID: nil)
        let files = try LocalArchiveExporter.export(sessions: [draft], checkIns: [], journalEntries: [journal])
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        let csv = try String(contentsOf: try XCTUnwrap(files.first { $0.pathExtension == "csv" }), encoding: .utf8)
        XCTAssertTrue(csv.contains("\"simulator\""))
        XCTAssertTrue(csv.contains("\"1025\""))
        let json = try String(contentsOf: try XCTUnwrap(files.first { $0.pathExtension == "json" }), encoding: .utf8)
        XCTAssertTrue(json.contains("line one"))
        XCTAssertTrue(json.contains("simulator"))
    }

    func testHistoricalEligibleSessionDoesNotBecomeTodaysReadiness() throws {
        let start = Date(timeIntervalSinceNow: -2 * 86_400)
        var draft = try SessionDraft(purpose: .restingCheckIn, origin: .polarH9, startedAtUTC: start)
        for index in 0..<200 {
            try draft.append(HeartRateSampleValue(beatsPerMinute: 60, receivedAtUTC: start.addingTimeInterval(Double(index)),
                                                  receivedMonotonicNanoseconds: UInt64(index), origin: .polarH9))
            try draft.append(RRIntervalValue(rawTicks1024: index.isMultiple(of: 2) ? 1_024 : 1_126,
                                             receivedAtUTC: start.addingTimeInterval(Double(index)),
                                             receivedMonotonicNanoseconds: UInt64(index), derivedBeatTimeUTC: nil,
                                             derivedBeatMonotonicNanoseconds: nil, origin: .polarH9))
        }
        try draft.complete(at: start.addingTimeInterval(240))
        XCTAssertNil(try ProductStore.makeReadiness(from: [draft]))
    }

    func testTrainingSegmentsSplitAtPause() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [0, 1, 2, 4, 5].map { second in
            HeartRateSampleValue(beatsPerMinute: 150, receivedAtUTC: start.addingTimeInterval(Double(second)),
                                 receivedMonotonicNanoseconds: UInt64(second) * 1_000_000_000, origin: .polarH9)
        }
        let pause = PauseIntervalValue(id: UUID(), startedAtUTC: start.addingTimeInterval(2.5),
                                       endedAtUTC: start.addingTimeInterval(3.5))
        let draft = try SessionDraft(purpose: .exerciseSession, origin: .polarH9, startedAtUTC: start,
                                     state: .recording, heartRates: samples, pauses: [pause])
        XCTAssertEqual(ProductStore.trainingSegments(for: draft).count, 2)
    }
}
