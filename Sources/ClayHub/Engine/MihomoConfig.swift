import Foundation

/// mihomo 配置文件的读写与生成。
///
/// config.yaml 里的 `# ===== ClayHub Managed =====` 段保存受管字段
/// （混合端口、订阅地址、订阅下载时间），其余内容用户可以随意编辑；
/// 重新下载订阅时只覆盖受管段之后生成的代理内容，不破坏手工改动。
enum MihomoConfig {
    nonisolated static let managedMarkerBegin = "# ===== ClayHub Managed (do not remove) ====="
    nonisolated static let managedMarkerEnd = "# ===== End ClayHub Managed ====="

    // MARK: - 受管字段解析

    struct ManagedFields {
        var port: Int
        var subscriptionURL: String
        var subscriptionUpdatedAt: Date?
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
        subscriptionUpdatedAt: Date?
    ) throws {
        let configURL = MihomoInstaller.configURL(home: home)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: MihomoInstaller.configDirectoryURL(home: home),
            withIntermediateDirectories: true
        )

        let existing = try? String(contentsOf: configURL, encoding: .utf8)
        let body = try stripSubscriptionContent(from: existing)
        let yaml = renderYAML(
            body: body,
            port: port,
            subscriptionURL: subscriptionURL,
            subscriptionUpdatedAt: subscriptionUpdatedAt
        )
        try yaml.data(using: .utf8)!.write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: configURL.path
        )
    }

    /// 拿掉旧受管段之后、下一个顶层键之前由订阅生成的内容，保留用户手写部分。
    private static func stripSubscriptionContent(from text: String?) throws -> String {
        guard let text, !text.isEmpty else { return "" }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 移除受管段注释本身
        if let begin = lines.firstIndex(of: managedMarkerBegin) {
            if let end = lines.firstIndex(of: managedMarkerEnd), end > begin {
                lines.removeSubrange(begin...end)
            } else {
                lines.removeSubrange(begin...)
            }
        }
        // 移除旧的订阅生成段（proxies 及其后到下一个顶层键的内容由重新渲染接管）
        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderYAML(
        body: String,
        port: Int,
        subscriptionURL: String,
        subscriptionUpdatedAt: Date?
    ) -> String {
        var out: [String] = []
        out.append(managedMarkerBegin)
        out.append("# subscription-url: \(subscriptionURL)")
        if let subscriptionUpdatedAt {
            out.append("# subscription-updated: \(String(format: "%.0f", subscriptionUpdatedAt.timeIntervalSince1970))")
        }
        out.append(managedMarkerEnd)
        out.append("")
        out.append("mixed-port: \(port)")
        out.append("bind-address: 127.0.0.1")
        out.append("mode: rule")
        out.append("log-level: info")
        out.append("ipv6: false")
        out.append("allow-lan: false")
        out.append("external-controller: \"\"")
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
    /// 订阅文件里的 mixed-port / external-controller 等监听字段以受管值为准。
    static func applySubscription(
        subscriptionYAML: String,
        port: Int,
        subscriptionURL: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let sanitized = removeListenerFields(from: subscriptionYAML)
        let fileManager = FileManager.default
        let configURL = MihomoInstaller.configURL(home: home)
        try fileManager.createDirectory(
            at: MihomoInstaller.configDirectoryURL(home: home),
            withIntermediateDirectories: true
        )

        var out: [String] = []
        out.append(managedMarkerBegin)
        out.append("# subscription-url: \(subscriptionURL)")
        out.append("# subscription-updated: \(String(format: "%.0f", Date().timeIntervalSince1970))")
        out.append(managedMarkerEnd)
        out.append("")
        out.append("mixed-port: \(port)")
        out.append("bind-address: 127.0.0.1")
        out.append("mode: rule")
        out.append("log-level: info")
        out.append("ipv6: false")
        out.append("allow-lan: false")
        out.append("external-controller: \"\"")
        out.append("")
        out.append(sanitized.trimmingCharacters(in: .whitespacesAndNewlines))

        let yaml = out.joined(separator: "\n") + "\n"
        try yaml.data(using: .utf8)!.write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: configURL.path
        )
    }

    /// mihomo 的规则模式下监听相关字段一律由 ClayHub 受管，订阅里带来的
    /// 端口、TUN、external-controller 覆盖全部剥掉。
    private static func removeListenerFields(from yaml: String) -> String {
        let forbidden = [
            "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
            "allow-lan", "bind-address", "external-controller", "external-ui",
            "tun", "secret"
        ]
        var result: [String] = []
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#")
            if isTopLevel,
               let key = trimmed.split(separator: ":").first,
               forbidden.contains(String(key)) {
                continue
            }
            result.append(String(line))
        }
        return result.joined(separator: "\n")
    }
}
