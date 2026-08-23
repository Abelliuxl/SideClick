import Foundation

/// 负责受管服务定义的持久化（JSON 文件），并预置内建服务。
final class MCPStore {
    static let shared = MCPStore()

    private enum Keys {
        static let builtInServiceVersion = "ClayHubBuiltInServiceVersion"
    }

    private static let currentBuiltInServiceVersion = 3

    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var directoryURL: URL {
        let dir = home
            .appendingPathComponent("Library/Application Support/ClayHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent("mcp-servers.json")
    }

    func load() -> [MCPServerDefinition] {
        var servers: [MCPServerDefinition]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MCPServerDefinition].self, from: data) {
            servers = decoded
        } else {
            servers = Self.defaultServers()
        }

        let defaults = UserDefaults.standard
        let installedVersion = defaults.integer(forKey: Keys.builtInServiceVersion)
        if installedVersion < Self.currentBuiltInServiceVersion {
            servers = Self.migratingBuiltInServices(
                servers,
                fromVersion: installedVersion
            )
            defaults.set(Self.currentBuiltInServiceVersion, forKey: Keys.builtInServiceVersion)
        }
        return servers
    }

    func save(_ servers: [MCPServerDefinition]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 默认服务器

    /// 首次运行预置的五个受管服务：
    /// 1. vision-mcp —— 本地常驻 HTTP 视觉分析服务；
    /// 2. exa-search —— 本地 exa（经 supergateway 桥接为常驻 HTTP/SSE）；
    /// 3. qwen-mm-api —— Qwen 多模态 API（stdio 经 loopback HTTP 桥接）；
    /// 4. deepseek-harness —— 普通本地 Web 服务，不同步到 ZCode MCP 配置；
    /// 5. cli-proxy-api —— CLIProxyAPI 本地 API 代理，默认关闭，需先安装。
    static func defaultServers() -> [MCPServerDefinition] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let visionRoot = home.appendingPathComponent("Workplace/vision-mcp")
        let python = visionRoot.appendingPathComponent(".venv/bin/python")
        let script = visionRoot.appendingPathComponent("proxy/vision_proxy.py")

        let vision = MCPServerDefinition(
            name: "vision-mcp",
            transport: .http,
            url: "http://127.0.0.1:8766/mcp",
            command: python.path,
            args: [
                script.path,
                "--transport", "http",
                "--host", "127.0.0.1",
                "--port", "8766",
                "--path", "/mcp"
            ],
            cwd: visionRoot.path,
            isEnabled: true,
            healthURL: "http://127.0.0.1:8766/health"
        )

        let exa = MCPServerDefinition(
            name: "exa-search",
            transport: .http,
            url: "http://127.0.0.1:8767/mcp",
            command: "npx",
            args: [
                "-y", "supergateway",
                "--stdio", "npx -y exa-mcp-server@3.4.0",
                "--port", "8767",
                "--outputTransport", "streamableHttp",
                "--healthEndpoint", "/healthz"
            ],
            env: ["EXA_API_KEY": existingExaAPIKey()],
            isEnabled: true,
            healthURL: "http://127.0.0.1:8767/healthz"
        )

        return [
            vision,
            exa,
            qwenMMAPI(home: home),
            deepSeekHarness(home: home),
            cliProxyAPI(home: home)
        ]
    }

    static func addingMissingBuiltInServices(
        to servers: [MCPServerDefinition]
    ) -> [MCPServerDefinition] {
        var result = servers
        if !result.contains(where: { $0.name == "deepseek-harness" }) {
            result.append(deepSeekHarness(home: FileManager.default.homeDirectoryForCurrentUser))
        }
        if !result.contains(where: { $0.name == "qwen-mm-api" }) {
            result.append(qwenMMAPI(home: FileManager.default.homeDirectoryForCurrentUser))
        }
        if !result.contains(where: { $0.name == CLIProxyAPIInstaller.serviceName }) {
            result.append(cliProxyAPI(home: FileManager.default.homeDirectoryForCurrentUser))
        }
        return result
    }

    static func migratingBuiltInServices(
        _ servers: [MCPServerDefinition],
        fromVersion: Int
    ) -> [MCPServerDefinition] {
        var result = addingMissingBuiltInServices(to: servers)
        if fromVersion < 2,
           let visionIndex = result.firstIndex(where: { $0.name == "vision-mcp" }) {
            // Qwen becomes the active multimodal server for the v2 migration.
            // Keep the old definition so the user can switch it back on at any time.
            result[visionIndex].isEnabled = false
        }
        return result
    }

    static func qwenMMAPI(home: URL) -> MCPServerDefinition {
        let uvx = home.appendingPathComponent(".local/bin/uvx").path
        let nodeBin = home.appendingPathComponent(
            "ZCodeProject/.toolchain/node-v24.19.0-darwin-arm64/bin"
        )
        let qwenPackage = [
            "qwen-mm-plugins[api] @",
            "git+https://github.com/QwenLM/Qwen-MM-Plugins.git@qwen-mm-plugins-api-v1.0.3"
        ].joined(separator: " ")

        return MCPServerDefinition(
            id: UUID(uuidString: "A11F00D0-0000-4000-8000-000000008768")!,
            name: "qwen-mm-api",
            transport: .http,
            url: "http://127.0.0.1:8768/mcp",
            command: uvx,
            args: [
                "--from", "mcp-proxy==0.12.0",
                "--with", "mcp>=1.17,<2",
                "mcp-proxy",
                "--host", "127.0.0.1",
                "--port", "8768",
                "--pass-environment",
                "--",
                uvx,
                "--from", qwenPackage,
                "qwen-mm-plugins-api"
            ],
            env: [
                // Keep all Qwen configuration in ClayHub so a GUI/login launch
                // behaves exactly like an interactive shell launch.
                "DASHSCOPE_API_KEY": "",
                "DASHSCOPE_BASE_URL": "https://dashscope.aliyuncs.com/compatible-mode/v1",
                "QWEN_MM_API_VL_MODEL": "qwen3.7-plus",
                "QWEN_MM_API_OMNI_MODEL": "qwen3.5-omni-plus",
                "PATH": [
                    home.appendingPathComponent(".local/bin").path,
                    nodeBin.path,
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin"
                ].joined(separator: ":")
            ],
            isEnabled: true,
            healthURL: "http://127.0.0.1:8768/status"
        )
    }

    static func deepSeekHarness(home: URL) -> MCPServerDefinition {
        let projectRoot = home.appendingPathComponent("Workplace/deepseek-harness")
        let nodeBin = home.appendingPathComponent(
            "ZCodeProject/.toolchain/node-v24.19.0-darwin-arm64/bin"
        )

        return MCPServerDefinition(
            id: UUID(uuidString: "D33F5EEC-0000-4000-8000-000000000308")!,
            name: "deepseek-harness",
            kind: .local,
            transport: .http,
            url: "http://127.0.0.1:3080",
            command: nodeBin.appendingPathComponent("npx").path,
            args: ["-y", "pnpm@11.7.0", "dsh", "web", "--host", "127.0.0.1", "--port", "3080"],
            env: [
                "PATH": [
                    nodeBin.path,
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin"
                ].joined(separator: ":")
            ],
            cwd: projectRoot.path,
            isEnabled: true,
            healthURL: "http://127.0.0.1:3080"
        )
    }

    static func cliProxyAPI(home: URL) -> MCPServerDefinition {
        MCPServerDefinition(
            id: UUID(uuidString: "C11F00D0-0000-4000-8000-000000008317")!,
            name: CLIProxyAPIInstaller.serviceName,
            kind: .local,
            transport: .http,
            url: "http://127.0.0.1:\(CLIProxyAPIInstaller.defaultPort)",
            command: CLIProxyAPIInstaller.currentExecutableURL(home: home).path,
            args: [
                "--config",
                CLIProxyAPIInstaller.configURL(home: home).path
            ],
            cwd: CLIProxyAPIInstaller.installRootURL(home: home).path,
            // The binary is installed on demand. Do not report a failed service
            // on first launch before the user has chosen to install it.
            isEnabled: false,
            healthURL: "http://127.0.0.1:\(CLIProxyAPIInstaller.defaultPort)/v1/models"
        )
    }

    /// 从现有 ZCode 配置里读取 exa 的 API key（避免把密钥写死在源码里）。
    /// 找不到时返回空字符串，用户在 GUI 里补填即可。
    private static func existingExaAPIKey() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcp = json["mcp"] as? [String: Any],
              let servers = mcp["servers"] as? [String: Any] else {
            return ""
        }

        // 旧配置形式：url 里带 ?exaApiKey=...
        if let exa = servers["exa-search"] as? [String: Any],
           let rawURL = exa["url"] as? String,
           let components = URLComponents(string: rawURL),
           let key = components.queryItems?.first(where: { $0.name == "exaApiKey" })?.value {
            return key
        }

        // 新的 headers 形式
        if let exa = servers["exa-search"] as? [String: Any],
           let headers = exa["headers"] as? [String: String],
           let key = headers["x-api-key"] ?? headers["X-API-Key"] {
            return key
        }

        return ""
    }
}
