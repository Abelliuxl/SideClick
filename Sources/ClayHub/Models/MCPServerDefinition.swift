import Foundation

/// MCP 传输类型：远程 HTTP / SSE，或本地 stdio 进程。
enum MCPTransport: String, Codable, CaseIterable {
    case http
    case sse
    case stdio
}

/// 条目用途。MCP 服务会同步给 ZCode；普通本地服务只由 ClayHub 托管。
enum ManagedServiceKind: String, Codable, CaseIterable {
    case mcp
    case local

    var displayName: String {
        switch self {
        case .mcp: return "MCP Server"
        case .local: return "Local Service"
        }
    }
}

/// 一个受管服务的完整定义。既可以是 MCP 端点，也可以是只由 ClayHub
/// 托管生命周期、不会同步到 ZCode 的普通本地进程。
struct MCPServerDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var kind: ManagedServiceKind
    var transport: MCPTransport

    // 远程（http/sse）
    var url: String
    var headers: [String: String]

    // 本地进程
    var command: String
    var args: [String]
    var env: [String: String]
    var cwd: String

    // 行为：启用的条目由 ClayHub 托管，并随 ClayHub 启停。
    var isEnabled: Bool
    var healthURL: String

    /// 是否需要 ClayHub 拉起一个本地进程（command 非空）。
    var runsLocalProcess: Bool { !command.isEmpty }

    /// 是否有健康检查地址（用于 http/sse 常驻服务的就绪探测）。
    var hasHealthCheck: Bool { !healthURL.isEmpty }

    init(
        id: UUID = UUID(),
        name: String,
        kind: ManagedServiceKind = .mcp,
        transport: MCPTransport,
        url: String = "",
        headers: [String: String] = [:],
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String = "",
        isEnabled: Bool = false,
        healthURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.transport = transport
        self.url = url
        self.headers = headers
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.isEnabled = isEnabled
        self.healthURL = healthURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, transport, url, headers, command, args, env, cwd
        case isEnabled
        case autoStart
        case healthURL
    }

    /// `autoStart` was the old name for the same persisted intent. Decode it
    /// as a fallback so existing installations migrate without losing state.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(ManagedServiceKind.self, forKey: .kind) ?? .mcp
        transport = try container.decode(MCPTransport.self, forKey: .transport)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .autoStart)
            ?? false
        healthURL = try container.decodeIfPresent(String.self, forKey: .healthURL) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(transport, forKey: .transport)
        try container.encode(url, forKey: .url)
        try container.encode(headers, forKey: .headers)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(env, forKey: .env)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(healthURL, forKey: .healthURL)
    }

    /// 生成写入 ZCode（`~/.zcode/cli/config.json` 的 `mcp.servers.<name>`）的字典。
    var zcodeDictionary: [String: Any] {
        switch transport {
        case .http, .sse:
            var dict: [String: Any] = [
                "type": transport.rawValue,
                "url": url
            ]
            if !headers.isEmpty {
                dict["headers"] = headers
            }
            return dict
        case .stdio:
            var dict: [String: Any] = [
                "type": "stdio",
                "command": command,
                "args": args
            ]
            if !env.isEmpty {
                dict["env"] = env
            }
            return dict
        }
    }

    /// 把 "KEY=VALUE" 多行文本解析成环境变量字典。
    static func envDict(fromText text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let idx = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<idx].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// 把环境变量字典转成 "KEY=VALUE" 多行文本。
    static func envText(fromDict dict: [String: String]) -> String {
        dict.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}
