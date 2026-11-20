import XCTest
@testable import DSHRemote

final class ConnectionTests: XCTestCase {
    func testPrivateRouteClassification() {
        for host in ["10.0.0.1", "192.168.1.2", "172.16.0.1", "172.31.255.1", "169.254.1.1", "127.0.0.1", "localhost", "host.local", "[::1]", "[fd12::1]", "[fe80::1]"] { XCTAssertTrue(PortalRoute.isLAN(URL(string: "http://\(host)/")!), host) }
        for host in ["172.15.1.1", "172.32.0.1", "192.168.1.example", "fc.example", "8.8.8.8", "relay.example"] { XCTAssertFalse(PortalRoute.isLAN(URL(string: "https://\(host)/")!), host) }
    }
    func testLANSucceedsDuringRelayGrace() async throws {
        let urls = [URL(string: "https://relay.example/")!, URL(string: "http://192.168.1.2/")!]
        let result = try await PortalClient.race(urls, lanGraceNanoseconds: 100_000_000) { url in
            try await Task.sleep(nanoseconds: PortalRoute.isLAN(url) ? 30_000_000 : 1_000_000)
            return 1
        }
        XCTAssertEqual(result.base, urls[1])
    }
    func testRelayFallbackWhenLANFailsOrMissesGrace() async throws {
        let urls = [URL(string: "https://relay.example/")!, URL(string: "http://10.0.0.1/")!]
        for fails in [false, true] {
            let result = try await PortalClient.race(urls, lanGraceNanoseconds: 10_000_000) { url in
                if PortalRoute.isLAN(url) {
                    if fails { throw URLError(.cannotConnectToHost) }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                return 1
            }
            XCTAssertEqual(result.base, urls[0])
        }
    }
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
