import XCTest
@testable import DSHRemote

final class ConnectionTests: XCTestCase {
    func testNormalizationKeepsPrefix() throws {
        XCTAssertEqual(try PortalURL.normalize(" https://relay.example/__t/abc?x=1 ").absoluteString, "https://relay.example/__t/abc/")
        XCTAssertEqual(try PortalURL.normalize("http://192.168.1.5:3081").absoluteString, "http://192.168.1.5:3081/")
        XCTAssertThrowsError(try PortalURL.normalize(""))
        XCTAssertThrowsError(try PortalURL.normalize("file:///etc/passwd"))
        XCTAssertThrowsError(try PortalURL.normalize("https://user:pass@host/"))
    }
    func testPairing() throws {
        let pair = try XCTUnwrap(PortalURL.pairing("https://relay.example/__t/id/__portal/pair?t=a%2Bb"))
        XCTAssertEqual(pair.0.absoluteString, "https://relay.example/__t/id/")
        XCTAssertEqual(pair.1, "a+b")
        XCTAssertNil(try PortalURL.pairing("https://host/"))
        XCTAssertThrowsError(try PortalURL.pairing("https://host/__portal/pair?t="))
        XCTAssertEqual(String(data: PortalURL.form(["password": "a+b &中"]), encoding: .utf8), "password=a%2Bb%20%26%E4%B8%AD")
    }
    func testRaceSkipsFailureAndPicksFastestOK() async throws {
        let urls = ["http://fail/", "http://slow/", "http://fast/"].map { URL(string: $0)! }
        let result = try await PortalClient.race(urls) { url in
            if url.host == "fail" { throw URLError(.cannotConnectToHost) }
            try await Task.sleep(nanoseconds: url.host == "fast" ? 10_000_000 : 500_000_000)
            return url.host == "fast" ? 10 : 500
        }
        XCTAssertEqual(result.base.host, "fast")
    }
    func testEmptyAndFailedRace() async {
        for urls in [[], [URL(string: "http://fail/")!]] {
            do { _ = try await PortalClient.race(urls) { _ in throw URLError(.timedOut) }; XCTFail("Expected failure") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
}
