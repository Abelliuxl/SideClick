import XCTest
import Darwin
@testable import ClayHub

final class ClayHubTests: XCTestCase {
    func testMouseButtonRawValues() {
        XCTAssertEqual(MouseButton.left.rawValue, 0)
        XCTAssertEqual(MouseButton.right.rawValue, 1)
        XCTAssertEqual(MouseButton.middle.rawValue, 2)
        XCTAssertEqual(MouseButton.sideBack.rawValue, 3)
        XCTAssertEqual(MouseButton.sideForward.rawValue, 4)
        XCTAssertEqual(MouseButton(rawValue: 8).displayName, "Mouse Button 8")
    }

    func testKeyCombinationEquality() {
        let a = KeyCombination(keyCode: 2, modifiers: [.command])
        let b = KeyCombination(keyCode: 2, modifiers: [.command])
        let c = KeyCombination(keyCode: 2, modifiers: [.command, .shift])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testModifierFlagsDisplay() {
        let flags: KeyCombination.ModifierFlags = [.command, .shift]
        XCTAssertTrue(flags.displayString.contains("⌘"))
        XCTAssertTrue(flags.displayString.contains("⇧"))
    }

    func testModifierKeyEvents() {
        let flags: KeyCombination.ModifierFlags = [.control, .command]
        let keyEvents = flags.keyEvents

        XCTAssertEqual(keyEvents.map(\.keyCode), [59, 55])
    }

    func testArrowKeyDisplayNames() {
        XCTAssertEqual(KeyCombination(keyCode: 123, modifiers: [.control]).displayName, "⌃Left")
        XCTAssertEqual(KeyCombination(keyCode: 124, modifiers: [.control]).displayName, "⌃Right")
    }

    func testBindingManagerPersistence() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = BindingManager(defaults: defaults)
        let combo = KeyCombination(keyCode: 2, modifiers: [.command])
        manager.setBinding(combo, for: .sideBack)
        let reloaded = BindingManager(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .sideBack), combo)
    }

    func testLegacySideClickStartAtLaunchMigratesToEnabled() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "ClayHubSideClickStartAtLaunch")

        let manager = BindingManager(defaults: defaults)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(defaults.object(forKey: "ClayHubSideClickEnabled") as? Bool, false)
    }

    func testSideClickEnabledChangePersistsAndNotifiesOnce() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = BindingManager(defaults: defaults)
        var observed: [Bool] = []
        manager.onEnabledChange = { observed.append($0) }

        manager.isEnabled = false
        manager.isEnabled = false

        XCTAssertEqual(observed, [false])
        XCTAssertEqual(defaults.object(forKey: "ClayHubSideClickEnabled") as? Bool, false)
    }

    func testLegacyAutoStartMigratesToEnabled() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "legacy-service",
          "transport": "stdio",
          "url": "",
          "headers": {},
          "command": "/usr/bin/true",
          "args": [],
          "env": {},
          "cwd": "",
          "autoStart": true,
          "healthURL": ""
        }
        """

        let server = try JSONDecoder().decode(
            MCPServerDefinition.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(server.isEnabled)
        XCTAssertEqual(server.kind, .mcp)

        let encoded = try JSONEncoder().encode(server)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["isEnabled"] as? Bool, true)
        XCTAssertNil(object["autoStart"])
    }

    func testDeepSeekHarnessBuiltInService() {
        let home = URL(fileURLWithPath: "/Users/example")
        let service = MCPStore.deepSeekHarness(home: home)

        XCTAssertEqual(service.name, "deepseek-harness")
        XCTAssertEqual(service.kind, .local)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.cwd, "/Users/example/Workplace/deepseek-harness")
        XCTAssertEqual(
            service.command,
            "/Users/example/ZCodeProject/.toolchain/node-v24.19.0-darwin-arm64/bin/npx"
        )
        XCTAssertEqual(service.args, [
            "-y", "pnpm@11.7.0", "dsh", "web",
            "--host", "127.0.0.1", "--port", "3080"
        ])
        XCTAssertEqual(service.healthURL, "http://127.0.0.1:3080")
    }

    func testAddingDeepSeekBuiltInIsIdempotent() {
        let first = MCPStore.addingMissingBuiltInServices(to: [])
        let second = MCPStore.addingMissingBuiltInServices(to: first)

        XCTAssertEqual(
            Set(first.map(\.name)),
            ["deepseek-harness", "qwen-mm-api", "cli-proxy-api", "mihomo"]
        )
        XCTAssertEqual(second, first)
    }

    func testCLIProxyAPIBuiltInService() {
        let home = URL(fileURLWithPath: "/Users/example")
        let service = MCPStore.cliProxyAPI(home: home)

        XCTAssertEqual(service.name, "cli-proxy-api")
        XCTAssertEqual(service.kind, .local)
        XCTAssertEqual(service.transport, .http)
        XCTAssertEqual(service.url, "http://127.0.0.1:8317")
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(
            service.command,
            "/Users/example/Library/Application Support/ClayHub/Services/CLIProxyAPI/current/cli-proxy-api"
        )
        XCTAssertEqual(
            service.args,
            ["--config", "/Users/example/.cli-proxy-api/config.yaml"]
        )
        XCTAssertEqual(service.healthURL, "http://127.0.0.1:8317/v1/models")
    }

    func testCLIProxyAPIConfigurationTemplateIsLoopbackOnly() {
        let config = CLIProxyAPIInstaller.defaultConfiguration(
            home: URL(fileURLWithPath: "/Users/example"),
            apiKey: "test-key"
        )

        XCTAssertTrue(config.contains("host: \"127.0.0.1\""))
        XCTAssertTrue(config.contains("port: 8317"))
        XCTAssertTrue(config.contains("auth-dir: \"~/.cli-proxy-api\""))
        XCTAssertTrue(config.contains("- \"test-key\""))
        XCTAssertTrue(config.contains("allow-remote: false"))
    }

    func testQwenMMAPIBuiltInService() {
        let home = URL(fileURLWithPath: "/Users/example")
        let service = MCPStore.qwenMMAPI(home: home)

        XCTAssertEqual(service.name, "qwen-mm-api")
        XCTAssertEqual(service.kind, .mcp)
        XCTAssertEqual(service.transport, .http)
        XCTAssertEqual(service.url, "http://127.0.0.1:8768/mcp")
        XCTAssertEqual(service.command, "/Users/example/.local/bin/uvx")
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.healthURL, "http://127.0.0.1:8768/status")
        XCTAssertEqual(service.env["DASHSCOPE_API_KEY"], "")
        XCTAssertEqual(
            service.env["DASHSCOPE_BASE_URL"],
            "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(service.env["QWEN_MM_API_VL_MODEL"], "qwen3.7-plus")
        XCTAssertEqual(service.env["QWEN_MM_API_OMNI_MODEL"], "qwen3.5-omni-plus")
        XCTAssertTrue(service.args.contains("127.0.0.1"))
        XCTAssertTrue(service.args.contains("mcp>=1.17,<2"))
        XCTAssertTrue(service.args.contains(where: { $0.contains("qwen-mm-plugins-api-v1.0.3") }))
    }

    func testQwenMigrationKeepsVisionButDisablesIt() {
        let vision = MCPServerDefinition(
            name: "vision-mcp",
            transport: .http,
            url: "http://127.0.0.1:8766/mcp",
            isEnabled: true
        )

        let migrated = MCPStore.migratingBuiltInServices([vision], fromVersion: 1)

        XCTAssertEqual(migrated.first(where: { $0.name == "vision-mcp" })?.isEnabled, false)
        XCTAssertEqual(migrated.first(where: { $0.name == "qwen-mm-api" })?.isEnabled, true)
    }

    func testOnlyEnabledMCPServersAreExportedToZCode() {
        let mcp = MCPServerDefinition(
            name: "mcp",
            transport: .http,
            url: "http://127.0.0.1:9000",
            isEnabled: true
        )
        let local = MCPServerDefinition(
            name: "local",
            kind: .local,
            transport: .http,
            url: "http://127.0.0.1:3080",
            isEnabled: true
        )
        let disabled = MCPServerDefinition(
            name: "disabled",
            transport: .http,
            url: "http://127.0.0.1:9001",
            isEnabled: false
        )

        XCTAssertEqual(ZCodeConfigSync.exportedServers(from: [mcp, local, disabled]), [mcp])
    }

    func testLocalServiceHealthAcceptsAnHTTP404() {
        XCTAssertTrue(MCPManager.isHealthyHTTPStatus(404, for: .local))
        XCTAssertFalse(MCPManager.isHealthyHTTPStatus(404, for: .mcp))
        XCTAssertTrue(MCPManager.isHealthyHTTPStatus(204, for: .mcp))
    }

    func testConfiguredPATHKeepsHighestPriority() {
        let path = MCPManager.augmentedPATH(base: "/custom/node/bin:/usr/bin")

        XCTAssertTrue(path.hasPrefix("/custom/node/bin:/usr/bin:"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
    }

    @MainActor
    func testEnabledToggleStartsAndStopsOwnedProcess() throws {
        let server = MCPServerDefinition(
            name: "lifecycle-test",
            transport: .stdio,
            command: "/bin/sleep",
            args: ["30"]
        )
        let manager = MCPManager(
            initialServers: [server],
            persistsChanges: false,
            monitorsHealth: false
        )

        manager.setEnabled(true, for: server.id)
        let pid = try XCTUnwrap(manager.state(for: server.id).pid)
        XCTAssertEqual(manager.state(for: server.id).status, .running)
        XCTAssertEqual(Darwin.kill(pid, 0), 0)

        manager.setEnabled(false, for: server.id)
        XCTAssertEqual(manager.state(for: server.id).status, .stopped)
        XCTAssertTrue(waitUntilProcessExits(pid))
    }

    @MainActor
    func testDisablingServiceStopsDescendantProcesses() throws {
        let server = MCPServerDefinition(
            name: "process-tree-test",
            transport: .stdio,
            command: "/bin/sh",
            args: ["-c", "sleep 30 & wait"]
        )
        let manager = MCPManager(
            initialServers: [server],
            persistsChanges: false,
            monitorsHealth: false
        )

        manager.setEnabled(true, for: server.id)
        let rootPID = try XCTUnwrap(manager.state(for: server.id).pid)
        let childPID = try XCTUnwrap(waitForChildProcess(of: rootPID))

        manager.setEnabled(false, for: server.id)
        XCTAssertTrue(waitUntilProcessExits(rootPID))
        XCTAssertTrue(waitUntilProcessExits(childPID))
    }

    private func waitForChildProcess(of parent: pid_t) -> pid_t? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let capacity = proc_listchildpids(parent, nil, 0)
            if capacity > 0 {
                var buffer = [pid_t](repeating: 0, count: Int(capacity))
                let count = buffer.withUnsafeMutableBytes { bytes in
                    proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
                }
                if count > 0, let child = buffer.prefix(Int(count)).first(where: { $0 > 0 }) {
                    return child
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return nil
    }

    private func waitUntilProcessExits(_ pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if Darwin.kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "ClayHubTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
