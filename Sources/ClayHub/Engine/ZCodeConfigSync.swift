import Foundation

/// 把 ClayHub 管理的 MCP 服务器同步写入 ZCode 的用户配置
/// `~/.zcode/cli/config.json` 的 `mcp.servers`，替换同名条目、保留其它条目，
/// 并移除之前由 ClayHub 写入但现已删除的条目。
enum ZCodeConfigSync {
    private static let managedNamesKey = "ClayHubManagedMCPServerNames"

    static func sync(managed: [MCPServerDefinition]) {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/config.json")

        var root: [String: Any]
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        } else {
            root = [:]
        }

        var mcp = root["mcp"] as? [String: Any] ?? [:]
        var servers = mcp["servers"] as? [String: Any] ?? [:]

        let enabled = exportedServers(from: managed)
        let currentNames = Set(enabled.map(\.name))
        let previouslyManaged = Set(UserDefaults.standard.stringArray(forKey: managedNamesKey) ?? [])

        // 1. 移除已不再受管的旧条目
        for stale in previouslyManaged where !currentNames.contains(stale) {
            servers.removeValue(forKey: stale)
        }

        // 2. 写入/更新当前受管的服务器
        for server in enabled {
            servers[server.name] = server.zcodeDictionary
        }

        // 3. 记录当前受管的名字集合
        UserDefaults.standard.set(Array(currentNames).sorted(), forKey: managedNamesKey)

        mcp["servers"] = servers
        root["mcp"] = mcp

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? data.write(to: configURL, options: .atomic)
    }

    /// 普通本地服务由 ClayHub 管理生命周期，但不属于 MCP 配置。
    static func exportedServers(
        from managed: [MCPServerDefinition]
    ) -> [MCPServerDefinition] {
        managed.filter { $0.isEnabled && $0.kind == .mcp }
    }
}
