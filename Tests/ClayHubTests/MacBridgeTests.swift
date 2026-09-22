import XCTest
@testable import ClayHub

final class MacBridgeTests: XCTestCase {
    private func snapshot(error: String? = nil, updated: Double = 1000,
                          poll: Double = 999, pid: Int32 = 12) -> BridgeSnapshot {
        BridgeSnapshot(version: 1, pid: pid, startedAt: 900, updatedAt: updated,
                       phase: "polling", lastPollAt: poll, lastResultAt: 999,
                       error: error, eventError: nil, pendingReceipts: 0,
                       rejectedReceipts: 1, history: [])
    }

    func testLiveProcessWith409IsNotHealthy() {
        XCTAssertNotNil(snapshot(error: "relay_http_409").problem(now: 1001, runningPID: 12))
        XCTAssertNil(snapshot().problem(now: 1001, runningPID: 12))
    }

    func testHeartbeatAloneDoesNotProvePollingHealth() {
        XCTAssertNotNil(snapshot(poll: 800).problem(now: 1001, runningPID: 12))
    }

    func testStaleOrPreviousProcessSnapshotIsRejected() {
        XCTAssertNotNil(snapshot(updated: 950).problem(now: 1001, runningPID: 12))
        XCTAssertNotNil(snapshot().problem(now: 1001, runningPID: 99))
        XCTAssertNotNil(snapshot().problem(now: 1001, runningPID: nil))
    }

    func testPythonSnapshotDecoding() throws {
        let raw = """
        {"version":1,"pid":12,"started_at":900,"updated_at":1000,"phase":"polling",
         "last_poll_at":999,"last_result_at":null,"error":null,"event_error":null,
         "pending_receipts":0,"rejected_receipts":0,"history":[{"at":900,"code":"starting"}]}
        """
        let value = try BridgeSnapshot.decode(Data(raw.utf8))
        XCTAssertEqual(value.pid, 12)
        XCTAssertEqual(value.lastPollAt, 999)
        XCTAssertNil(value.lastResultAt)
    }

    func testLaunchctlPIDParsingDoesNotTreatExitCodeAsPID() {
        XCTAssertNil(MacBridgeMonitor.parsePID("\"LastExitStatus\" = 15;"))
        XCTAssertEqual(MacBridgeMonitor.parsePID("\"LastExitStatus\" = 15;\n\"PID\" = 124;"), 124)
    }

    func testDisableOverrideParsingCoversBothLaunchctlFormats() {
        let list = """
        disabled services = {
            "com.liuxl.server94-proxy" => disabled
            "com.liuxl.macbridge.agent" => enabled
        }
        """
        XCTAssertFalse(MacBridgeMonitor.parseDisabled(list, label: "com.liuxl.macbridge.agent"))
        XCTAssertTrue(MacBridgeMonitor.parseDisabled(list, label: "com.liuxl.server94-proxy"))
        XCTAssertTrue(MacBridgeMonitor.parseDisabled("""
        disabled services = {
            "com.liuxl.macbridge.agent" => true
        }
        """, label: "com.liuxl.macbridge.agent"))
        // Absent from the override list means launchd will load it again.
        XCTAssertFalse(MacBridgeMonitor.parseDisabled(list, label: "com.liuxl.other"))
        XCTAssertFalse(MacBridgeMonitor.parseDisabled("", label: "com.liuxl.macbridge.agent"))
    }

    func testUnknownDiagnosticIsNeverDisplayedVerbatim() {
        XCTAssertEqual(BridgeSnapshot.explain("private payload"), "未知状态")
    }
    func testNotificationsDebounceDeduplicateAndRecover() {
        var policy = BridgeAlertPolicy()
        XCTAssertNil(policy.update(state: "failed", now: 0, enabled: true))
        XCTAssertNil(policy.update(state: "failed", now: 29, enabled: true))
        XCTAssertEqual(policy.update(state: "failed", now: 30, enabled: true), "failed")
        XCTAssertNil(policy.update(state: "failed", now: 90, enabled: true))
        XCTAssertEqual(policy.update(state: "running", now: 91, enabled: true), "recovered")
        XCTAssertNil(policy.update(state: "running", now: 92, enabled: true))
        XCTAssertNil(policy.update(state: "failed", now: 93, enabled: true))
    }

    func testMutedAndBriefFaultsDoNotNotify() {
        var policy = BridgeAlertPolicy()
        XCTAssertNil(policy.update(state: "failed", now: 0, enabled: false))
        XCTAssertNil(policy.update(state: "failed", now: 60, enabled: false))
        XCTAssertNil(policy.update(state: "running", now: 61, enabled: true))
        XCTAssertNil(policy.update(state: "failed", now: 62, enabled: true))
        XCTAssertNil(policy.update(state: "running", now: 63, enabled: true))
    }
}
