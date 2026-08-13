import Foundation

/// MCP 传输类型：远程 HTTP / SSE，或本地 stdio 进程。
enum MCPTransport: String, Codable, CaseIterable {
    case http
    case sse
    case stdio
}

/// 一个 MCP 服务器的完整定义。既可以是一个远程 URL（http/sse），
/// 也可以是一个由 ClayHub 托管启动的本地进程（stdio 或带健康检查的常驻服务）。
struct MCPServerDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var transport: MCPTransport

    // 远程（http/sse）
    var url: String
    var headers: [String: String]

    // 本地进程
    var command: String
    var args: [String]
    var env: [String: String]
    var cwd: String

    // 行为
    var autoStart: Bool
    var healthURL: String

    /// 是否需要 ClayHub 拉起一个本地进程（command 非空）。
    var runsLocalProcess: Bool { !command.isEmpty }

    /// 是否有健康检查地址（用于 http/sse 常驻服务的就绪探测）。
    var hasHealthCheck: Bool { !healthURL.isEmpty }

    init(
        id: UUID = UUID(),
        name: String,
        transport: MCPTransport,
        url: String = "",
        headers: [String: String] = [:],
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String = "",
        autoStart: Bool = false,
        healthURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.headers = headers
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.autoStart = autoStart
        self.healthURL = healthURL
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
