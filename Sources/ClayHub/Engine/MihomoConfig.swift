import Foundation
import SystemConfiguration
import Darwin

/// mihomo 配置文件的读写与生成。
///
/// config.yaml 里的 `# ===== ClayHub Managed =====` 段保存受管字段
/// （混合端口、订阅地址、运行模式），其余内容用户可以随意编辑；
/// 重新下载订阅时只覆盖受管段，不破坏手工改动。
///
/// 运行模式的实现（mihomo 的内置 GLOBAL 组默认选中 DIRECT，无法用
/// 配置文件预设选中项，所以"全局"不走 mode: global）：
/// - `global`：引擎保持 rule 模式，规则替换为单条 `MATCH,PROXY`，
///   所有流量确定性地走 PROXY 组（当前即唯一节点）；
/// - `rule`：保留订阅自带的完整分流规则。
enum MihomoConfig {
    nonisolated static let managedMarkerBegin = "# ===== ClayHub Managed (do not remove) ====="
    nonisolated static let managedMarkerEnd = "# ===== End ClayHub Managed ====="

    /// 引擎级顶层键一律由受管段提供，订阅/手写带来的覆盖全部剥掉。
    nonisolated private static let managedEngineKeys: Set<String> = [
        "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
        "allow-lan", "bind-address", "external-controller", "external-ui",
        "tun", "secret", "mode", "log-level", "ipv6", "interface-name"
    ]

    /// 出站绑定的物理网卡。
    ///
    /// 当机器上有 TUN 型 VPN/代理（Clash Verge TUN、Tailscale 出口节点等）
    /// 接管默认路由时，mihomo 连接代理节点服务器本身也会被送进隧道，
    /// 形成环路导致握手失败。把出站绑定到物理网卡可绕开该问题；
    /// 没有隧道时绑定物理网卡也是正常路径，无副作用。
    nonisolated static func primaryPhysicalInterface() -> String? {
        // 优先取系统主接口；TUN 生效时它可能返回 utun*，忽略。
        if let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString),
           let dict = value as? [String: Any],
           let primary = dict["PrimaryInterface"] as? String,
           primary.hasPrefix("en") {
            return primary
        }

        // 回退：枚举带 IPv4 地址的 en* 接口，优先 en0。
        var candidates: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            defer { freeifaddrs(head) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
                guard let addr = ptr.pointee.ifa_addr,
                      addr.pointee.sa_family == UInt8(AF_INET) else { continue }
                let name = String(cString: ptr.pointee.ifa_name)
                guard name.hasPrefix("en") else { continue }
                candidates.append(name)
            }
        }
        return candidates.first(where: { $0 == "en0" }) ?? candidates.sorted().first
    }

    // MARK: - 受管字段解析

    struct ManagedFields {
        var port: Int
        var subscriptionURL: String
        var subscriptionUpdatedAt: Date?
        var mode: String = "rule"
    }

    /// 从现有 config.yaml 读受管字段；读不到时回退默认值。
    static func readManagedFields(home: URL) -> ManagedFields {
        var fields = ManagedFields(port: MihomoInstaller.defaultPort, subscriptionURL: "", subscriptionUpdatedAt: nil)
        guard let text = try? String(contentsOf: MihomoInstaller.configURL(home: home), encoding: .utf8) else {
            return fields
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("mixed-port:") {
                let value = trimmed.dropFirst("mixed-port:".count).trimmingCharacters(in: .whitespaces)
                fields.port = Int(value) ?? fields.port
            } else if trimmed.hasPrefix("# subscription-url:") {
                fields.subscriptionURL = String(trimmed.dropFirst("# subscription-url:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("# subscription-updated:") {
                let value = trimmed.dropFirst("# subscription-updated:".count).trimmingCharacters(in: .whitespaces)
                if let interval = TimeInterval(value) {
                    fields.subscriptionUpdatedAt = Date(timeIntervalSince1970: interval)
                }
            } else if trimmed.hasPrefix("# managed-mode:") {
                let value = trimmed.dropFirst("# managed-mode:".count).trimmingCharacters(in: .whitespaces)
                if value == "global" || value == "rule" { fields.mode = value }
            }
        }
        return fields
    }

    // MARK: - 保存端口 / 订阅（不触碰用户手工编辑的其余内容）

    /// 仅更新受管字段。端口改动直接改 `mixed-port:`；订阅地址改动会清空
    /// 旧的订阅生成的节点段，用户需要重新「下载订阅」。
    static func saveManagedFields(
        home: URL,
        port: Int,
        subscriptionURL: String,
        subscriptionUpdatedAt: Date?,
        mode: String = "rule",
        interfaceName: String? = MihomoConfig.primaryPhysicalInterface()
    ) throws {
        let configURL = MihomoInstaller.configURL(home: home)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: MihomoInstaller.configDirectoryURL(home: home),
            withIntermediateDirectories: true
        )

        let existing = try? String(contentsOf: configURL, encoding: .utf8)
        var body = try stripManagedMarkers(from: existing)
        body = stripTopLevelSections(body, keys: managedEngineKeys)
        if mode == "global" {
            body = stripTopLevelSections(body, keys: ["rules", "rule-providers"])
            body = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nrules:\n  - MATCH,PROXY"
        }
        let yaml = renderYAML(
            body: body,
            port: port,
            subscriptionURL: subscriptionURL,
            subscriptionUpdatedAt: subscriptionUpdatedAt,
            mode: mode,
            interfaceName: interfaceName
        )
        try yaml.data(using: .utf8)!.write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: configURL.path
        )
    }

    /// 拿掉受管段注释本身，保留其余内容。
    private static func stripManagedMarkers(from text: String?) throws -> String {
        guard let text, !text.isEmpty else { return "" }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let begin = lines.firstIndex(of: managedMarkerBegin) {
            if let end = lines.firstIndex(of: managedMarkerEnd), end > begin {
                lines.removeSubrange(begin...end)
            } else {
                lines.removeSubrange(begin...)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 移除指定顶层键及其缩进子行（块级键如 `tun:` 的子键一并清掉）。
    private static func stripTopLevelSections(_ text: String, keys: Set<String>) -> String {
        var result: [String] = []
        var skippingBlock = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if skippingBlock {
                if isIndented || trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }
                skippingBlock = false
            }

            if !isIndented, !trimmed.hasPrefix("#"),
               let key = trimmed.split(separator: ":", maxSplits: 1).first,
               keys.contains(String(key)) {
                skippingBlock = true
                continue
            }
            result.append(String(line))
        }
        return result.joined(separator: "\n")
    }

    private static func renderYAML(
        body: String,
        port: Int,
        subscriptionURL: String,
        subscriptionUpdatedAt: Date?,
        mode: String = "rule",
        interfaceName: String? = nil
    ) -> String {
        var out: [String] = []
        out.append(managedMarkerBegin)
        out.append("# subscription-url: \(subscriptionURL)")
        if let subscriptionUpdatedAt {
            out.append("# subscription-updated: \(String(format: "%.0f", subscriptionUpdatedAt.timeIntervalSince1970))")
        }
        out.append("# managed-mode: \(mode)")
        out.append(managedMarkerEnd)
        out.append("")
        out.append("mixed-port: \(port)")
        out.append("bind-address: 127.0.0.1")
        // 引擎固定 rule 模式：全局语义由 MATCH,PROXY 兜底规则实现，
        // 绕开内置 GLOBAL 组默认选中 DIRECT 且无法预设的问题。
        out.append("mode: rule")
        out.append("log-level: info")
        out.append("ipv6: false")
        out.append("allow-lan: false")
        out.append("external-controller: \"\"")
        if let interfaceName, !interfaceName.isEmpty {
            out.append("interface-name: \(interfaceName)")
        }
        out.append("")
        out.append(body.isEmpty ? "# 在下方粘贴或由订阅生成 proxies / proxy-groups / rules" : body)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - 订阅下载

    enum SubscriptionError: LocalizedError {
        case invalidURL
        case emptyContent
        case notYAML

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "订阅地址格式不正确。"
            case .emptyContent: return "订阅返回了空内容。"
            case .notYAML: return "订阅内容不是有效的 YAML 配置。"
            }
        }
    }

    /// 下载订阅 URL 的内容，直接作为 mihomo YAML 配置。mihomo 原生支持
    /// Clash YAML 订阅；base64 节点列表订阅需要转换服务，这里不做。
    static func downloadSubscription(urlString: String) async throws -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https" else {
            throw SubscriptionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("clash.meta/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SubscriptionError.emptyContent
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SubscriptionError.emptyContent
        }
        // 粗校验：YAML 订阅应包含 proxies 键；base64 或纯文本直接拒绝。
        guard text.contains("proxies:") else {
            throw SubscriptionError.notYAML
        }
        return text
    }

    /// 把订阅 YAML 与受管字段合成最终 config.yaml。
    /// 订阅里的监听字段与运行模式一律以受管值为准。
    static func applySubscription(
        subscriptionYAML: String,
        port: Int,
        subscriptionURL: String,
        mode: String = "rule",
        interfaceName: String? = MihomoConfig.primaryPhysicalInterface(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        var body = stripTopLevelSections(subscriptionYAML, keys: managedEngineKeys)
        if mode == "global" {
            body = stripTopLevelSections(body, keys: ["rules", "rule-providers"])
            body = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nrules:\n  - MATCH,PROXY"
        }

        let fileManager = FileManager.default
        let configURL = MihomoInstaller.configURL(home: home)
        try fileManager.createDirectory(
            at: MihomoInstaller.configDirectoryURL(home: home),
            withIntermediateDirectories: true
        )

        let yaml = renderYAML(
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            subscriptionURL: subscriptionURL,
            subscriptionUpdatedAt: Date(),
            mode: mode,
            interfaceName: interfaceName
        )
        try yaml.data(using: .utf8)!.write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: configURL.path
        )
    }
}
