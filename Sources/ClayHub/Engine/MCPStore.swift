import Foundation

/// 负责 MCP 服务器定义的持久化（JSON 文件），并在首次运行时预置默认服务器。
final class MCPStore {
    static let shared = MCPStore()

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
        guard let data = try? Data(contentsOf: fileURL),
              let servers = try? JSONDecoder().decode([MCPServerDefinition].self, from: data) else {
            return Self.defaultServers()
        }
        return servers
    }

    func save(_ servers: [MCPServerDefinition]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 默认服务器

    /// 首次运行预置的两个受管服务：
    /// 1. vision-mcp —— 本地常驻 HTTP 视觉分析服务；
    /// 2. exa-search —— 本地 exa（经 supergateway 桥接为常驻 HTTP/SSE）。
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
            autoStart: true,
            healthURL: "http://127.0.0.1:8766/health"
        )

        let exa = MCPServerDefinition(
            name: "exa-search",
            transport: .sse,
            url: "http://127.0.0.1:8767/sse",
            command: "npx",
            args: [
                "-y", "supergateway",
                "--stdio", "npx -y exa-mcp-server@3.4.0",
                "--port", "8767",
                "--healthEndpoint", "/healthz"
            ],
            env: ["EXA_API_KEY": existingExaAPIKey()],
            autoStart: true,
            healthURL: "http://127.0.0.1:8767/healthz"
        )

        return [vision, exa]
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
