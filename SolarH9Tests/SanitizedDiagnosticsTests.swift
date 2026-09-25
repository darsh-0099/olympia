import XCTest
@testable import SolarH9

@MainActor
final class SanitizedDiagnosticsTests: XCTestCase {
    func testTrailIsBoundedAndOrdered() async {
        let diagnostics = SanitizedDiagnostics(capacity: 2)
        let first = Date(timeIntervalSince1970: 1)
        let second = Date(timeIntervalSince1970: 2)
        let third = Date(timeIntervalSince1970: 3)

        await diagnostics.record(.appLaunched, at: first)
        await diagnostics.record(.sensorConnected, at: second)
        await diagnostics.record(.recordingCompleted, at: third)

        let events = await diagnostics.snapshot()
        XCTAssertEqual(events, [
            .init(timestampUTC: second, severity: .information, code: .sensorConnected),
            .init(timestampUTC: third, severity: .information, code: .recordingCompleted)
        ])
    }

    func testEncodedDiagnosticsContainOnlyReviewedFields() async throws {
        let diagnostics = SanitizedDiagnostics()
        await diagnostics.record(
            .recordingPersistenceDegraded,
            severity: .error,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try await diagnostics.encodedJSON()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(object.first).keys), ["code", "severity", "timestampUTC"])
        XCTAssertEqual(object.first?["code"] as? String, "recordingPersistenceDegraded")
        XCTAssertNil(object.first?["heartRate"])
        XCTAssertNil(object.first?["rrIntervals"])
        XCTAssertNil(object.first?["message"])
    }

    func testRemoveAllClearsTrail() async {
        let diagnostics = SanitizedDiagnostics()
        await diagnostics.record(.persistenceOpened)
        await diagnostics.removeAll()
        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.isEmpty)
    }
}
