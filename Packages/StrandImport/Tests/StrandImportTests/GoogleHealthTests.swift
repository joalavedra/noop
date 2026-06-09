import XCTest
@testable import StrandImport

final class GoogleHealthTests: XCTestCase {

    // MARK: - Mapper

    func testMapHeartRate() {
        let point: [String: Any] = ["heartRate": [
            "beatsPerMinute": 62,
            "sampleTime": ["physicalTime": "2026-06-08T12:00:00Z", "utcOffset": "-14400s"],
        ]]
        var out = GoogleHealthMapper.Mapped()
        GoogleHealthMapper.map(type: "heart-rate", points: [point], into: &out)
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples.first?.type, "HeartRate")
        XCTAssertEqual(out.samples.first?.value, 62)
        XCTAssertEqual(out.samples.first?.tzOffsetMin, -240)
    }

    func testMapSleepStagesAndInBed() {
        let point: [String: Any] = ["sleep": [
            "interval": [
                "startTime": "2026-06-08T04:00:00Z", "endTime": "2026-06-08T11:00:00Z",
                "startUtcOffset": "-14400s", "endUtcOffset": "-14400s",
            ],
            "stages": [
                ["type": "DEEP", "startTime": "2026-06-08T04:30:00Z", "endTime": "2026-06-08T05:00:00Z"],
                ["type": "REM", "startTime": "2026-06-08T05:00:00Z", "endTime": "2026-06-08T05:30:00Z"],
            ],
        ]]
        var out = GoogleHealthMapper.Mapped()
        GoogleHealthMapper.map(type: "sleep", points: [point], into: &out)
        XCTAssertEqual(out.sleepIntervals.count, 3) // InBed + 2 stages
        XCTAssertTrue(out.sleepIntervals.contains { $0.stage == .inBed })
        XCTAssertTrue(out.sleepIntervals.contains { $0.stage == .asleepDeep })
        XCTAssertTrue(out.sleepIntervals.contains { $0.stage == .asleepREM })
    }

    func testOxygenSaturationStaysPercentage() {
        let point: [String: Any] = ["oxygenSaturation": [
            "percentage": 97,
            "sampleTime": ["physicalTime": "2026-06-08T12:00:00Z", "utcOffset": "0s"],
        ]]
        var out = GoogleHealthMapper.Mapped()
        GoogleHealthMapper.map(type: "oxygen-saturation", points: [point], into: &out)
        XCTAssertEqual(out.samples.first?.type, "OxygenSaturation")
        XCTAssertEqual(out.samples.first?.value, 97)
    }

    func testWeightGramsToKilograms() {
        let point: [String: Any] = ["weight": [
            "weightGrams": 80000,
            "sampleTime": ["physicalTime": "2026-06-06T12:00:00Z", "utcOffset": "0s"],
        ]]
        var out = GoogleHealthMapper.Mapped()
        GoogleHealthMapper.map(type: "weight", points: [point], into: &out)
        XCTAssertEqual(out.samples.first?.type, "BodyMass")
        XCTAssertEqual(out.samples.first?.value, 80)
    }

    // MARK: - Auth helpers

    func testPKCEAndConsentURL() {
        let (verifier, challenge) = GoogleHealthAuth.pkce()
        XCTAssertGreaterThanOrEqual(verifier.count, 40)
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        let url = GoogleHealthAuth(clientId: "cid", clientSecret: "sec").consentURL(challenge: challenge)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "cid")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "access_type" }?.value, "offline")
    }

    func testExtractCode() {
        let request = "GET /?code=ABC123&scope=x HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertEqual(GoogleHealthAuth.extractCode(request), "ABC123")
        XCTAssertNil(GoogleHealthAuth.extractCode("GET /?error=access_denied HTTP/1.1\r\n"))
    }

    #if os(macOS)
    func testLoopbackListenerCatchesCode() async throws {
        let auth = GoogleHealthAuth(clientId: "cid", clientSecret: "sec", port: 8137)
        let code = try await auth.withLoopbackListener {
            Task {
                let url = URL(string: "http://localhost:8137/?code=ROUNDTRIP&scope=foo")!
                _ = try? await URLSession.shared.data(from: url)
            }
        }
        XCTAssertEqual(code, "ROUNDTRIP")
    }
    #endif
}
