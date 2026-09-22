import Foundation
import Darwin

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

    private let store = MCPStore.shared
    private var processes: [UUID: Process] = [:]
    private var waitingForEndpoint = Set<UUID>()
    private var healthTimer: Timer?
    private var isShuttingDown = false
    private let queue = DispatchQueue(
        label: "clayhub.mcp",
        qos: .utility,
        attributes: .concurrent
    )
    private let persistsChanges: Bool

    init(
        initialServers: [MCPServerDefinition]? = nil,
        persistsChanges: Bool = true,
        monitorsHealth: Bool = true
    ) {
        let loaded = initialServers ?? store.load()
        self.persistsChanges = persistsChanges
        self.servers = loaded
        for server in loaded {
            states[server.id] = MCPServerState()
        }
        if monitorsHealth {
            startHealthTimer()
        }
        // 首次启动：持久化默认配置，并同步到 ZCode（否则 ZCode 里看不到受管服务器）
        if persistsChanges {
            store.save(loaded)
            ZCodeConfigSync.sync(managed: loaded)
        }
    }

    deinit {
        healthTimer?.invalidate()
    }

    // MARK: - 查询

    func state(for id: UUID) -> MCPServerState {
        states[id] ?? MCPServerState()
    }

    // MARK: - 生命周期

    func startEnabledServices() {
        guard !isShuttingDown else { return }
        for server in servers where server.isEnabled {
            start(server)
        }
    }

    func start(_ requestedServer: MCPServerDefinition) {
        guard !isShuttingDown,
              let server = servers.first(where: { $0.id == requestedServer.id }),
              server.isEnabled else { return }

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

        // 不接管 ClayHub 之外的进程，否则退出时无法兑现“一起退出”。
        // 上一次运行被强杀/崩溃时遗留的自家进程仍然算自家进程：先清掉它再重建受管进程，
        // 避免出现“端点可用但卡片一直红着”的状态。真正的第三方占用者仍然明确报错。
        if server.hasHealthCheck {
            queue.async { [weak self] in
                guard let self else { return }
                if self.isHealthy(server) {
                    let reclaimed = self.reclaimOwnedLeftover(for: server)
                    DispatchQueue.main.async {
                        guard self.isEnabled(server.id) else { return }
                        if reclaimed {
                            self.appendLog(
                                "\n[reclaimed endpoint left by a previous ClayHub run: \(server.healthURL)]\n",
                                for: server.id
                            )
                            self.spawn(server)
                        } else {
                            self.waitingForEndpoint.insert(server.id)
                            self.setStatus(.failed, for: server.id)
                            self.appendLog(
                                "\n[endpoint is already served by a process ClayHub does not own: \(server.healthURL)]\n",
                                for: server.id
                            )
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        guard !self.isShuttingDown,
                              let latest = self.servers.first(where: { $0.id == server.id }),
                              latest.isEnabled else { return }
                        self.spawn(latest)
                    }
                }
            }
            return
        }

        spawn(server)
    }

    private func spawn(_ server: MCPServerDefinition) {
        guard !isShuttingDown,
              isEnabled(server.id),
              processes[server.id] == nil else { return }

        waitingForEndpoint.remove(server.id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveExecutable(server.command))
        process.arguments = server.args
        if !server.cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: server.cwd)
        }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in server.env { env[key] = value }
        env["PATH"] = Self.augmentedPATH(base: env["PATH"])
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
                if self.isEnabled(id) {
                    self.setStatus(.failed, for: id)
                    self.appendLog("\n[process exited, status \(finished.terminationStatus)]\n", for: id)
                } else {
                    self.setStatus(.stopped, for: id)
                }
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
        waitingForEndpoint.remove(server.id)
        if let tree = detachOwnedProcess(for: server.id) {
            terminate([tree], waitForExit: false)
        }
        setPid(nil, for: server.id)
        setStatus(.stopped, for: server.id)
        appendLog("\n[stopped]\n", for: server.id)
    }

    /// 退出时并行停止所有受管进程树，最多等待两秒后强制清理。
    func stopAll() {
        isShuttingDown = true
        waitingForEndpoint.removeAll()
        healthTimer?.invalidate()
        healthTimer = nil
        let trees = Array(processes.keys).compactMap { detachOwnedProcess(for: $0) }
        for server in servers {
            setPid(nil, for: server.id)
            setStatus(.stopped, for: server.id)
        }
        terminate(trees, waitForExit: true)
    }

    func restart(_ server: MCPServerDefinition) {
        guard isEnabled(server.id) else { return }
        stop(server)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self,
                  let latest = self.servers.first(where: { $0.id == server.id }),
                  latest.isEnabled else { return }
            self.start(latest)
        }
    }

    // MARK: - 增删改

    func add(_ server: MCPServerDefinition) {
        servers.append(server)
        states[server.id] = MCPServerState()
        persistAndSync()
        if server.isEnabled {
            start(server)
        }
    }

    func update(_ server: MCPServerDefinition) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let previous = servers[index]
        servers[index] = server
        persistAndSync()

        switch (previous.isEnabled, server.isEnabled) {
        case (false, true):
            start(server)
        case (true, false):
            stop(server)
        case (true, true):
            // An enabled service must apply edited command, endpoint and env now.
            restart(server)
        case (false, false):
            break
        }
    }

    /// 启用状态就是 Hub 对条目的托管意图：持久化后立即启停。
    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }),
              servers[index].isEnabled != enabled else { return }

        servers[index].isEnabled = enabled
        let server = servers[index]
        persistAndSync()

        if enabled {
            start(server)
        } else {
            stop(server)
        }
    }

    /// 单独更新某个服务器的环境变量（用于「环境变量」输入框）。
    /// 若该服务正在运行，则重启以应用新环境。
    func updateEnvironment(_ env: [String: String], for server: MCPServerDefinition) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].env = env
        persistAndSync()

        if servers[index].isEnabled {
            restart(servers[index])
        }
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
        guard persistsChanges else { return }
        store.save(servers)
        ZCodeConfigSync.sync(managed: servers)
    }

    // MARK: - 健康探测

    private func probeHealth(_ server: MCPServerDefinition) {
        let id = server.id
        guard server.hasHealthCheck else {
            if isEnabled(id) {
                setStatus(.running, for: id)
            }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            var healthy = false
            // 首次启动可能要下载依赖（npx 拉包），给足时间：约 30 秒
            for _ in 0..<60 {
                if self.isHealthy(server) { healthy = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                guard let latest = self.servers.first(where: { $0.id == id }),
                      latest.isEnabled,
                      latest.healthURL == server.healthURL else { return }

                if latest.runsLocalProcess,
                   self.processes[id]?.isRunning != true {
                    self.setStatus(.failed, for: id)
                    return
                }

                self.setStatus(healthy ? .running : .failed, for: id)
                if !healthy {
                    self.appendLog("\n[health check failed: \(server.healthURL)]\n", for: id)
                }
            }
        }
    }

    private func refreshHealth() {
        let candidates = servers.filter {
            let status = states[$0.id]?.status
            return $0.isEnabled
                && (status == .running || status == .failed || status == .starting)
                && $0.hasHealthCheck
        }
        for server in candidates {
            let id = server.id
            queue.async { [weak self] in
                guard let self else { return }
                let healthy = self.isHealthy(server)
                DispatchQueue.main.async {
                    guard let latest = self.servers.first(where: { $0.id == id }),
                          latest.isEnabled,
                          latest.healthURL == server.healthURL else { return }
                    let current = self.states[id]?.status
                    if healthy {
                        // 恢复：starting/failed → running
                        if !latest.runsLocalProcess || self.processes[id]?.isRunning == true {
                            if current != .running { self.setStatus(.running, for: id) }
                        }
                    } else {
                        if self.waitingForEndpoint.remove(id) != nil,
                           latest.runsLocalProcess,
                           self.processes[id] == nil {
                            self.setStatus(.starting, for: id)
                            self.spawn(latest)
                        } else if current == .running {
                            // 之前运行中、现在失联 → failed
                            self.setStatus(.failed, for: id)
                        }
                    }
                }
            }
        }
    }

    private func isHealthy(_ server: MCPServerDefinition) -> Bool {
        guard let url = URL(string: server.healthURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                ok = Self.isHealthyHTTPStatus(http.statusCode, for: server.kind)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3.5)
        return ok
    }

    /// MCP 条目通常提供专用的 2xx 健康端点。普通本地 Web 服务可能没有
    /// 健康路由；只要配置的端点能返回 HTTP 响应，就说明监听器已经就绪。
    static func isHealthyHTTPStatus(
        _ statusCode: Int,
        for kind: ManagedServiceKind
    ) -> Bool {
        switch kind {
        case .mcp:
            return (200..<300).contains(statusCode)
        case .local:
            return (100..<600).contains(statusCode)
        }
    }

    private func startHealthTimer() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshHealth()
        }
    }

    private func isEnabled(_ id: UUID) -> Bool {
        servers.first(where: { $0.id == id })?.isEnabled == true
    }

    // MARK: - 状态辅助（均切回主线程）

    private func mutateState(_ id: UUID, _ transform: @escaping (inout MCPServerState) -> Void) {
        let mutation = { [weak self] in
            guard let self else { return }
            var state = self.states[id] ?? MCPServerState()
            transform(&state)
            self.states[id] = state
        }

        if Thread.isMainThread {
            mutation()
        } else {
            DispatchQueue.main.async(execute: mutation)
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

    // MARK: - 端点残留回收

    /// `ps -Ao pid=,ppid=,command=` 的一行。命令行可能含空格，因此只切前两个字段。
    struct ProcessTableEntry {
        let pid: pid_t
        let ppid: pid_t
        let command: String
    }

    /// ClayHub 自己创建的管理目录。命令行里出现它们，就说明进程是本 App 拉起的，
    /// 别人的进程不会指向这里。
    nonisolated static var managedRoots: [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/ClayHub"
        return [root + "/mcp-runtimes", root + "/Services"]
    }

    /// 端点监听的本地端口：优先健康检查地址，其次服务地址。
    /// 远程地址通常省略端口，返回 nil 表示不需要做本地回收。
    nonisolated static func endpointPort(for server: MCPServerDefinition) -> Int? {
        for candidate in [server.healthURL, server.url] where !candidate.isEmpty {
            if let port = URL(string: candidate)?.port { return port }
        }
        return nil
    }

    nonisolated static func isOwnedCommand(_ command: String, managedRoots: [String]) -> Bool {
        managedRoots.contains { !$0.isEmpty && command.contains($0) }
    }

    nonisolated static func parseProcessTable(_ output: String) -> [pid_t: ProcessTableEntry] {
        var table: [pid_t: ProcessTableEntry] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            table[pid] = ProcessTableEntry(pid: pid, ppid: ppid, command: String(fields[2]))
        }
        return table
    }

    /// 从监听进程沿父链上溯，返回最上层的自家残留进程；整条链都不是自家进程时返回 nil。
    /// 需要上溯是因为监听者常常是包装脚本的子进程（sh → node/python）。
    nonisolated static func ownedAncestor(
        rootedAt pid: pid_t,
        in table: [pid_t: ProcessTableEntry],
        managedRoots: [String]
    ) -> pid_t? {
        var match: pid_t?
        var current = pid
        var hops = 0
        while hops < 16, let entry = table[current] {
            if isOwnedCommand(entry.command, managedRoots: managedRoots) { match = entry.pid }
            guard entry.ppid > 1, entry.ppid != current else { break }
            current = entry.ppid
            hops += 1
        }
        return match
    }

    /// 进程表里的后代进程（不含自身）。
    nonisolated static func descendants(
        of pid: pid_t,
        in table: [pid_t: ProcessTableEntry]
    ) -> [pid_t] {
        var result: [pid_t] = []
        var pending = table.values.filter { $0.ppid == pid }.map(\.pid)
        while let next = pending.popLast() {
            result.append(next)
            pending.append(contentsOf: table.values.filter { $0.ppid == next }.map(\.pid))
        }
        return result
    }

    /// 监听指定端口的进程。lsof 随 macOS 提供，不引入新依赖。
    nonisolated static func listenerPIDs(port: Int) -> [pid_t] {
        runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
            .split(whereSeparator: { $0.isNewline || $0 == " " })
            .compactMap { pid_t($0) }
            .filter { $0 > 0 }
    }

    nonisolated static func processTable() -> [pid_t: ProcessTableEntry] {
        parseProcessTable(runTool("/bin/ps", ["-Ao", "pid=,ppid=,command="]))
    }

    /// 固定工具的短命调用（lsof/ps），带超时，避免卡住探测队列。
    /// 输出先落临时文件而不是管道：`ps -A` 的输出远超管道缓冲区，用管道会
    /// 写端阻塞、读端等进程退出，互相等到超时。
    nonisolated private static func runTool(_ path: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clayhub-tool-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else { return "" }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return ""
        }
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 端点已被占用时，判断占用者是不是本 App 上一次运行遗留的进程：是则清掉整棵树，
    /// 让调用方随即拉起自己受管的进程。返回 true 仅在端点真的腾出来之后。
    private func reclaimOwnedLeftover(for server: MCPServerDefinition) -> Bool {
        guard processes[server.id] == nil,
              let port = Self.endpointPort(for: server) else { return false }

        let listeners = Self.listenerPIDs(port: port)
        guard !listeners.isEmpty else { return false }

        let table = Self.processTable()
        // 只保护我们自己拉起并正在监督的进程树（以及本进程），绝不误杀受管服务。
        var protectedPIDs = Set([getpid()])
        for process in processes.values {
            let root = process.processIdentifier
            protectedPIDs.insert(root)
            protectedPIDs.formUnion(Self.descendantPIDs(of: root))
        }
        let roots = Set(listeners.compactMap { pid -> pid_t? in
            guard let root = Self.ownedAncestor(
                rootedAt: pid,
                in: table,
                managedRoots: Self.managedRoots
            ), !protectedPIDs.contains(root) else { return nil }
            return root
        })
        guard !roots.isEmpty else { return false }

        let doomed = Set(roots.flatMap { [$0] + Self.descendants(of: $0, in: table) })
        for pid in doomed { _ = Darwin.kill(pid, SIGTERM) }
        if waitUntilEndpointCloses(server, timeout: 3.0) { return true }

        // 不理会 SIGTERM 的残留进程才强制结束；仍然占用则退回“被外部占用”的失败路径。
        for pid in doomed where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        return waitUntilEndpointCloses(server, timeout: 2.0)
    }

    /// 轮询直到健康端点不再响应，即端口真正腾出来。
    private func waitUntilEndpointCloses(_ server: MCPServerDefinition, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isHealthy(server) {
                // 监听套接字刚关闭，留一点时间给 launch 前的端口回收。
                Thread.sleep(forTimeInterval: 0.25)
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    // MARK: - 进程树清理

    private struct OwnedProcessTree {
        let process: Process
        let pids: [pid_t]
    }

    private func detachOwnedProcess(for id: UUID) -> OwnedProcessTree? {
        guard let process = processes.removeValue(forKey: id) else { return nil }
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil

        let rootPID = process.processIdentifier
        let descendants = Self.descendantPIDs(of: rootPID)
        return OwnedProcessTree(process: process, pids: descendants + [rootPID])
    }

    private func terminate(_ trees: [OwnedProcessTree], waitForExit: Bool) {
        guard !trees.isEmpty else { return }

        // 先向根进程发送 SIGTERM，让服务有机会自行清理；再覆盖整个后代树。
        for tree in trees where tree.process.isRunning {
            tree.process.terminate()
        }
        for pid in Set(trees.flatMap(\.pids)) {
            _ = Darwin.kill(pid, SIGTERM)
        }

        let cleanup = {
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline,
                  trees.contains(where: { $0.process.isRunning }) {
                Thread.sleep(forTimeInterval: 0.05)
            }

            for pid in Set(trees.flatMap(\.pids)) where Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        if waitForExit {
            cleanup()
        } else {
            queue.async(execute: cleanup)
        }
    }

    private static func descendantPIDs(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [parent]

        while let current = pending.popLast() {
            let children = childPIDs(of: current)
            result.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return result
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let capacity = proc_listchildpids(parent, nil, 0)
        guard capacity > 0 else { return [] }

        var buffer = [pid_t](repeating: 0, count: Int(capacity))
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
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

    /// 为子进程的 PATH 补上常见安装目录，同时保留条目自定义 PATH 的最高优先级。
    /// Finder / LaunchAgent 启动的 app 其 PATH 很精简，否则可能找不到 node/npx。
    static func augmentedPATH(base: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.local/bin",
            home + "/bin"
        ]
        // 条目显式配置的 PATH 必须保持最高优先级。例如 DeepSeek Harness
        // 依赖 Node 24，不能被 /opt/homebrew/bin 中较旧的 node 抢先解析。
        let parts = [base ?? ""] + extras
        return parts.filter { !$0.isEmpty }.joined(separator: ":")
    }
}
