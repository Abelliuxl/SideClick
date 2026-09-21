import XCTest
@testable import ClayHub

final class MihomoConfigTests: XCTestCase {
    private func makeSandboxHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MihomoConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func testMihomoBuiltInServicePointsAtManagedPaths() {
        let home = URL(fileURLWithPath: "/Users/example")
        let service = MCPStore.mihomo(home: home)

        XCTAssertEqual(service.name, "mihomo")
        XCTAssertEqual(service.kind, .local)
        XCTAssertEqual(
            service.command,
            home.appendingPathComponent("Library/Application Support/ClayHub/Services/mihomo/current/mihomo").path
        )
        XCTAssertEqual(service.url, "http://127.0.0.1:7891")
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.hasHealthCheck)
    }

    func testSaveAndReadManagedFieldsRoundTrip() throws {
        let home = makeSandboxHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try MihomoConfig.saveManagedFields(
            home: home,
            port: 7899,
            subscriptionURL: "https://example.com/sub",
            subscriptionUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let fields = MihomoConfig.readManagedFields(home: home)
        XCTAssertEqual(fields.port, 7899)
        XCTAssertEqual(fields.subscriptionURL, "https://example.com/sub")
        XCTAssertEqual(fields.subscriptionUpdatedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    }

    func testApplySubscriptionOverridesListenerFields() throws {
        let home = makeSandboxHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let subscription = """
        mixed-port: 9090
        allow-lan: true
        external-controller: 0.0.0.0:9091
        tun:
          enable: true
        proxies:
          - name: node-a
            type: ss
            server: a.example.com
            port: 8388
            cipher: aes-128-gcm
            password: secret
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - node-a
        rules:
          - MATCH,PROXY
        """

        try MihomoConfig.applySubscription(
            subscriptionYAML: subscription,
            port: 7905,
            subscriptionURL: "https://example.com/sub",
            home: home
        )

        let text = try String(contentsOf: MihomoInstaller.configURL(home: home), encoding: .utf8)
        XCTAssertTrue(text.contains("mixed-port: 7905"))
        XCTAssertFalse(text.contains("mixed-port: 9090"))
        XCTAssertFalse(text.contains("0.0.0.0"))
        XCTAssertFalse(text.contains("external-controller: 0"))
        // tun block from subscription is dropped entirely, indented children included
        XCTAssertFalse(text.contains("tun:"))
        XCTAssertFalse(text.contains("enable: true"))
        XCTAssertTrue(text.contains("allow-lan: false"))
        XCTAssertTrue(text.contains("node-a"))
        XCTAssertTrue(text.contains("MATCH,PROXY"))
        XCTAssertTrue(text.contains("# subscription-url: https://example.com/sub"))
    }

    func testDownloadSubscriptionRejectsNonYAMLContent() async {
        // A plain base64 node list has no "proxies:" key and must be rejected.
        do {
            _ = try await MihomoConfig.downloadSubscription(urlString: "not a url")
            XCTFail("expected invalidURL")
        } catch {
            // expected
        }
    }
}
