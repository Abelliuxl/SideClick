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

    func testEndpointPortComesFromHealthURLThenServiceURL() {
        let withHealth = MCPServerDefinition(
            name: "exa-search",
            transport: .http,
            url: "http://127.0.0.1:8767/mcp",
            healthURL: "http://127.0.0.1:8899/healthz"
        )
        XCTAssertEqual(MCPManager.endpointPort(for: withHealth), 8899)

        let local = MCPServerDefinition(
            name: "deepseek-harness",
            kind: .local,
            transport: .http,
            url: "http://127.0.0.1:3080"
        )
        XCTAssertEqual(MCPManager.endpointPort(for: local), 3080)

        let remote = MCPServerDefinition(
            name: "remote",
            transport: .http,
            url: "https://mcp.example.com/mcp"
        )
        XCTAssertNil(MCPManager.endpointPort(for: remote))
    }

    func testProcessTableParsingKeepsFullCommandLine() throws {
        let output = """
          5462  4873 /usr/local/bin/node /Users/x/exa/index.js --port 8767
          1     1 /sbin/launchd
        not-a-line
        """
        let table = MCPManager.parseProcessTable(output)

        XCTAssertEqual(table.count, 2)
        let entry = try XCTUnwrap(table[5462])
        XCTAssertEqual(entry.ppid, 4873)
        XCTAssertEqual(entry.command, "/usr/local/bin/node /Users/x/exa/index.js --port 8767")
        XCTAssertEqual(table[1]?.command, "/sbin/launchd")
    }

    func testOwnedAncestorOnlyMatchesClayHubManagedPaths() {
        let roots = ["/Users/x/Library/Application Support/ClayHub/mcp-runtimes",
                     "/Users/x/Library/Application Support/ClayHub/Services"]
        let table = MCPManager.parseProcessTable("""
            100 1 /bin/sh -c "/usr/local/bin/node /Users/x/Library/Application Support/ClayHub/mcp-runtimes/exa-search/supergateway/index.js & wait"
            101 100 /usr/local/bin/node /Users/x/Library/Application Support/ClayHub/mcp-runtimes/exa-search/supergateway/index.js --port 8767
            200 1 /bin/sh -c "python3 -m http.server 8899 & wait"
            201 200 /usr/bin/python3 -m http.server 8899
            300 1 /Applications/ClayHub.app/Contents/MacOS/ClayHub
            400 1 /Applications/ClayHub.app/Contents/MacOS/ClayHub
            401 400 /usr/local/bin/node /Users/x/Library/Application Support/ClayHub/Services/foo/bar --port 9000
        """)

        // 监听者本身是自家残留进程，且父链上还有包装脚本：返回最上层的自家进程。
        XCTAssertEqual(MCPManager.ownedAncestor(rootedAt: 101, in: table, managedRoots: roots), 100)
        // 监听者是包装脚本的子进程时，沿父链找到自家进程。
        XCTAssertEqual(MCPManager.ownedAncestor(rootedAt: 100, in: table, managedRoots: roots), 100)
        // 父进程是本 App 但不是残留（命令行不含管理目录）时，匹配监听者自身。
        XCTAssertEqual(MCPManager.ownedAncestor(rootedAt: 401, in: table, managedRoots: roots), 401)
        // 第三方进程（命令行不指向 ClayHub 管理目录）不属于自家。
        XCTAssertNil(MCPManager.ownedAncestor(rootedAt: 201, in: table, managedRoots: roots))
        XCTAssertNil(MCPManager.ownedAncestor(rootedAt: 300, in: table, managedRoots: roots))
        // 进程表里查不到时不做任何判断。
        XCTAssertNil(MCPManager.ownedAncestor(rootedAt: 999, in: table, managedRoots: roots))
    }

    func testDescendantsWalkTheWholeSubtree() {
        let table = MCPManager.parseProcessTable("""
            1 1 /sbin/launchd
            10 1 /bin/sh -c wrapper
            11 10 /usr/bin/python3 -m http.server
            12 11 /bin/sleep 30
            13 10 /bin/sleep 31
            20 1 /unrelated
        """)

        XCTAssertEqual(Set(MCPManager.descendants(of: 10, in: table)), [11, 12, 13])
        XCTAssertEqual(MCPManager.descendants(of: 12, in: table), [])
    }

    /// 上一次 ClayHub 被强杀后遗留的自家进程会继续占着端点。启动时应当先回收它，
    /// 再拉起受管的进程，而不是一直显示失败。
    func testStartReclaimsEndpointLeftByPreviousRun() throws {
        let port = 18993
        let healthURL = "http://127.0.0.1:\(port)/healthz"
        let serve = "/usr/bin/python3 -m http.server \(port) -b 127.0.0.1"
        let root = try XCTUnwrap(MCPManager.managedRoots.first)

        // 模拟残留进程：命令行里带着 ClayHub 的管理目录，监听者是包装脚本的子进程。
        let stale = Process()
        stale.executableURL = URL(fileURLWithPath: "/bin/sh")
        stale.arguments = ["-c", "\(serve) & wait # \(root)/stale-leftover"]
        stale.standardOutput = FileHandle.nullDevice
        stale.standardError = FileHandle.nullDevice
        try stale.run()
        let stalePID = stale.processIdentifier
        defer { cleanUpEndpoint(port: port, manager: nil, server: nil) }

        XCTAssertTrue(waitForHTTPResponse(healthURL), "残留进程应当先占住端口")
        XCTAssertFalse(
            MCPManager.listenerPIDs(port: port).contains(stalePID),
            "监听者应当是子进程，而不是包装脚本本身"
        )

        let server = MCPServerDefinition(
            name: "stale-endpoint-test",
            kind: .local,
            transport: .http,
            url: "http://127.0.0.1:\(port)",
            command: "/usr/bin/python3",
            args: ["-m", "http.server", "\(port)", "-b", "127.0.0.1"],
            isEnabled: false,
            healthURL: healthURL
        )
        let manager = MCPManager(
            initialServers: [server],
            persistsChanges: false,
            monitorsHealth: false
        )
        defer { cleanUpEndpoint(port: port, manager: manager, server: server) }

        manager.setEnabled(true, for: server.id)
        let running = pumpMainLoop(timeout: 45) {
            manager.state(for: server.id).status == .running
        }
        let state = manager.state(for: server.id)
        XCTAssertTrue(running, """
            应为 running，实际 status=\(state.status) pid=\(String(describing: state.pid)) \
            残留进程存活=\(Darwin.kill(stalePID, 0) == 0) 端口监听者=\(MCPManager.listenerPIDs(port: port)) \
            日志=\(state.log)
            """)

        let pid = try XCTUnwrap(manager.state(for: server.id).pid)
        XCTAssertNotEqual(pid, stalePID)
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        XCTAssertTrue(waitUntilProcessExits(stalePID), "残留进程应当被清掉")
        XCTAssertTrue(manager.state(for: server.id).log.contains("reclaimed endpoint"))
    }

    /// 第三方进程占用端点时仍然维持“不接管、明确报错”的行为。
    func testForeignEndpointIsStillReportedAsFailure() throws {
        let port = 18994
        let healthURL = "http://127.0.0.1:\(port)/healthz"

        let foreign = Process()
        foreign.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        foreign.arguments = ["-m", "http.server", "\(port)", "-b", "127.0.0.1"]
        foreign.standardOutput = FileHandle.nullDevice
        foreign.standardError = FileHandle.nullDevice
        try foreign.run()
        let foreignPID = foreign.processIdentifier
        defer { cleanUpEndpoint(port: port, manager: nil, server: nil) }

        XCTAssertTrue(waitForHTTPResponse(healthURL))

        let server = MCPServerDefinition(
            name: "foreign-endpoint-test",
            kind: .local,
            transport: .http,
            url: "http://127.0.0.1:\(port)",
            command: "/usr/bin/python3",
            args: ["-m", "http.server", "\(port)", "-b", "127.0.0.1"],
            isEnabled: false,
            healthURL: healthURL
        )
        let manager = MCPManager(
            initialServers: [server],
            persistsChanges: false,
            monitorsHealth: false
        )
        defer { cleanUpEndpoint(port: port, manager: manager, server: server) }

        manager.setEnabled(true, for: server.id)
        XCTAssertTrue(pumpMainLoop { manager.state(for: server.id).status == .failed })
        XCTAssertTrue(manager.state(for: server.id).log.contains("does not own"))
        XCTAssertEqual(Darwin.kill(foreignPID, 0), 0, "第三方进程不应被结束")
    }

    /// 让 main run loop 有机会执行 manager 的 DispatchQueue.main.async 回调。
    private func pumpMainLoop(timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func waitForHTTPResponse(_ url: String, timeout: TimeInterval = 10) -> Bool {
        guard let target = URL(string: url) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var answered = false
            let semaphore = DispatchSemaphore(value: 0)
            var request = URLRequest(url: target)
            request.timeoutInterval = 2
            URLSession.shared.dataTask(with: request) { _, response, _ in
                answered = response is HTTPURLResponse
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 2.5)
            if answered { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// 结束测试期间拉起的进程：先让 manager 正常停止受管进程，再兜底清掉仍占着端口的进程。
    /// 否则残留进程会继承测试进程的标准输出，让 swift test 一直等不到 EOF。
    private func cleanUpEndpoint(port: Int, manager: MCPManager?, server: MCPServerDefinition?) {
        if let manager, let server {
            manager.setEnabled(false, for: server.id)
        }
        for pid in MCPManager.listenerPIDs(port: port) {
            _ = Darwin.kill(pid, SIGKILL)
        }
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
