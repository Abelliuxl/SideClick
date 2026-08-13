import Foundation

/// MCP 服务器运行状态。
enum MCPServerStatus: String {
    case stopped
    case starting
    case running
    case failed
}

/// 单个 MCP 服务器的运行时状态（进程、日志、健康）。
struct MCPServerState {
    var status: MCPServerStatus = .stopped
    var pid: Int32?
    var log: String = ""
}

/// MCP 管理器：托管本地进程、健康探测、持久化、同步到 ZCode。
final class MCPManager: ObservableObject {
    @Published var servers: [MCPServerDefinition]
    @Published var states: [UUID: MCPServerState] = [:]
    @Published var launchAtLogin = false

    private let store = MCPStore.shared
    private var processes: [UUID: Process] = [:]
    private var healthTimer: Timer?
    private let queue = DispatchQueue(label: "clayhub.mcp", qos: .utility)

    init() {
        let loaded = store.load()
        self.servers = loaded
        for server in loaded {
            states[server.id] = MCPServerState()
        }
        refreshLaunchAtLoginStatus()
        startHealthTimer()
    }

    deinit {
        healthTimer?.invalidate()
    }

    // MARK: - 查询

    func state(for id: UUID) -> MCPServerState {
        states[id] ?? MCPServerState()
    }

    // MARK: - 生命周期

    func startAutoStartServices() {
        for server in servers where server.autoStart {
            start(server)
        }
    }

    func start(_ server: MCPServerDefinition) {
        guard server.runsLocalProcess else {
            // 纯远程服务：直接做一次健康探测
            setStatus(.starting, for: server.id)
            probeHealth(server)
            return
        }

        let current = states[server.id]?.status
        if current == .running || current == .starting { return }

        setStatus(.starting, for: server.id)
        setLog("", for: server.id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveExecutable(server.command))
        process.arguments = server.args
        if !server.cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: server.cwd)
        }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in server.env { env[key] = value }
        process.environment = env

        let id = server.id
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) { self?.appendLog(text, for: id) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) { self?.appendLog(text, for: id) }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.processes[id] != nil else { return }
                self.processes[id] = nil
                self.setPid(nil, for: id)
                self.setStatus(.failed, for: id)
                self.appendLog("\n[process exited, status \(finished.terminationStatus)]\n", for: id)
            }
        }

        do {
            try process.run()
            processes[id] = process
            setPid(process.processIdentifier, for: id)
            probeHealth(server)
        } catch {
            setStatus(.failed, for: id)
            appendLog("\n[launch error: \(error.localizedDescription)]\n", for: id)
        }
    }

    func stop(_ server: MCPServerDefinition) {
        if let process = processes[server.id] {
            processes[server.id] = nil
            process.terminationHandler = nil
            process.terminate()
        }
        setPid(nil, for: server.id)
        setStatus(.stopped, for: server.id)
        appendLog("\n[stopped]\n", for: server.id)
    }

    func restart(_ server: MCPServerDefinition) {
        stop(server)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start(server)
        }
    }

    // MARK: - 增删改

    func add(_ server: MCPServerDefinition) {
        servers.append(server)
        states[server.id] = MCPServerState()
        persistAndSync()
    }

    func update(_ server: MCPServerDefinition) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persistAndSync()
    }

    func remove(_ server: MCPServerDefinition) {
        stop(server)
        servers.removeAll { $0.id == server.id }
        states.removeValue(forKey: server.id)
        processes.removeValue(forKey: server.id)
        persistAndSync()
    }

    func clearLog(for id: UUID) {
        setLog("", for: id)
    }

    // MARK: - 持久化 & 同步

    private func persistAndSync() {
        store.save(servers)
        ZCodeConfigSync.sync(managed: servers)
    }

    // MARK: - 健康探测

    private func probeHealth(_ server: MCPServerDefinition) {
        let id = server.id
        guard server.hasHealthCheck else {
            setStatus(.running, for: id)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            var healthy = false
            for _ in 0..<10 {
                if self.isHealthy(server.healthURL) { healthy = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                self.setStatus(healthy ? .running : .failed, for: id)
                if !healthy {
                    self.appendLog("\n[health check failed: \(server.healthURL)]\n", for: id)
                }
            }
        }
    }

    private func refreshHealth() {
        let candidates = servers.filter {
            states[$0.id]?.status == .running && $0.hasHealthCheck
        }
        for server in candidates {
            let id = server.id
            queue.async { [weak self] in
                guard let self else { return }
                let healthy = self.isHealthy(server.healthURL)
                DispatchQueue.main.async {
                    let current = self.states[id]?.status
                    if current == .running && !healthy {
                        self.setStatus(.failed, for: id)
                    } else if current == .failed && healthy {
                        self.setStatus(.running, for: id)
                    }
                }
            }
        }
    }

    private func isHealthy(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                ok = (200..<300).contains(http.statusCode)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3.5)
        return ok
    }

    private func startHealthTimer() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshHealth()
        }
    }

    // MARK: - 开机自启

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = LaunchAtLoginController.isEnabled
    }

    func toggleLaunchAtLogin() {
        LaunchAtLoginController.setEnabled(!launchAtLogin)
        refreshLaunchAtLoginStatus()
    }

    // MARK: - 状态辅助（均切回主线程）

    private func mutateState(_ id: UUID, _ transform: @escaping (inout MCPServerState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var state = self.states[id] ?? MCPServerState()
            transform(&state)
            self.states[id] = state
        }
    }

    private func setStatus(_ status: MCPServerStatus, for id: UUID) {
        mutateState(id) { $0.status = status }
    }

    private func setPid(_ pid: Int32?, for id: UUID) {
        mutateState(id) { $0.pid = pid }
    }

    private func setLog(_ text: String, for id: UUID) {
        mutateState(id) { $0.log = text }
    }

    private func appendLog(_ text: String, for id: UUID) {
        mutateState(id) {
            $0.log += text
            if $0.log.count > 200_000 {
                $0.log = String($0.log.suffix(100_000))
            }
        }
    }

    // MARK: - 可执行文件解析

    private func resolveExecutable(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        if name.contains("/") { return name }

        var searchDirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs += path.split(separator: ":").map(String.init)
        }
        // Finder / LaunchAgent 启动时 PATH 很精简，补上常见安装位置
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        searchDirs += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            home + "/.local/bin",
            home + "/bin"
        ]
        for dir in searchDirs {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return name
    }
}
