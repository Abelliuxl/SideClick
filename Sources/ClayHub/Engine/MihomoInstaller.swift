import Foundation
import CryptoKit

/// mihomo 内核的本地安装与配置支持。
///
/// mihomo 是一个普通的 HTTP/SOCKS 代理内核，不是 MCP 服务。ClayHub 负责
/// 下载官方 macOS 构建、生成受管配置（固定 127.0.0.1 监听、单一混合端口、
/// 不启用 TUN、不接管系统代理）并托管它的生命周期；订阅转换后仍允许用户
/// 直接编辑配置文件。
@MainActor
final class MihomoInstaller: ObservableObject {
    static let shared = MihomoInstaller()

    nonisolated static let serviceName = "mihomo"
    nonisolated static let defaultPort = 7890

    @Published private(set) var isInstalling = false
    @Published private(set) var installedVersion: String?

    private init() {
        installedVersion = Self.installedVersion(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var isInstalled: Bool { installedVersion != nil }

    struct InstallResult {
        let version: String
        let executableURL: URL
        let configURL: URL
    }

    enum InstallerError: LocalizedError {
        case alreadyInstalling
        case invalidReleaseResponse
        case releaseAssetNotFound
        case decompressFailed
        case binaryNotFound
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyInstalling:
                return "mihomo 正在安装或更新。"
            case .invalidReleaseResponse:
                return "无法读取 mihomo 的最新版本信息。"
            case .releaseAssetNotFound:
                return "最新版本没有提供当前 Mac 所需的 mihomo 安装包。"
            case .decompressFailed:
                return "解压 mihomo 内核失败。"
            case .binaryNotFound:
                return "安装包中没有找到 mihomo 可执行文件。"
            case let .configurationFailed(message):
                return "准备 mihomo 配置失败：\(message)"
            }
        }
    }

    /// 下载并安装最新的官方 macOS 构建（arm64 / amd64），保留现有版本和用户配置。
    func installLatest() async throws -> InstallResult {
        guard !isInstalling else { throw InstallerError.alreadyInstalling }
        isInstalling = true
        defer {
            isInstalling = false
            installedVersion = Self.installedVersion(home: FileManager.default.homeDirectoryForCurrentUser)
        }

        let result = try await Self.performInstall(home: FileManager.default.homeDirectoryForCurrentUser)
        return result
    }

    // MARK: - 稳定路径（受管服务定义与 UI 共用）

    nonisolated static func installRootURL(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/ClayHub", isDirectory: true)
            .appendingPathComponent("Services/mihomo", isDirectory: true)
    }

    nonisolated static func currentExecutableURL(home: URL) -> URL {
        installRootURL(home: home)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("mihomo")
    }

    nonisolated static func configDirectoryURL(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/ClayHub", isDirectory: true)
            .appendingPathComponent("mihomo", isDirectory: true)
    }

    nonisolated static func configURL(home: URL) -> URL {
        configDirectoryURL(home: home).appendingPathComponent("config.yaml")
    }

    nonisolated static func installedVersion(home: URL) -> String? {
        let current = installRootURL(home: home).appendingPathComponent("current")
        guard FileManager.default.fileExists(atPath: current.path),
              FileManager.default.isExecutableFile(atPath: currentExecutableURL(home: home).path)
        else { return nil }

        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
            return URL(fileURLWithPath: destination).lastPathComponent
        }
        return "installed"
    }

    nonisolated private static let releaseAPI = URL(
        string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    )!

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    nonisolated private static func performInstall(home: URL) async throws -> InstallResult {
        let release = try await fetchRelease()
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard !version.isEmpty else { throw InstallerError.invalidReleaseResponse }

        guard let asset = release.assets.first(where: { $0.name == assetName(version: version) }) else {
            throw InstallerError.releaseAssetNotFound
        }

        let archiveData = try await fetch(asset.browserDownloadURL)

        let fileManager = FileManager.default
        let root = installRootURL(home: home)
        let versionRoot = root.appendingPathComponent(version, isDirectory: true)
        let tempRoot = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = tempRoot.appendingPathComponent(asset.name)

        do {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try archiveData.write(to: archiveURL, options: .atomic)

            let decompressed = try decompressGzip(archiveURL)
            guard let binaryData = decompressed else { throw InstallerError.decompressFailed }

            try fileManager.createDirectory(at: versionRoot, withIntermediateDirectories: true)
            let installedBinary = versionRoot.appendingPathComponent("mihomo")
            if fileManager.fileExists(atPath: installedBinary.path) {
                try fileManager.removeItem(at: installedBinary)
            }
            try binaryData.write(to: installedBinary, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: installedBinary.path
            )

            try updateCurrentLink(root: root, version: version)

            try? fileManager.removeItem(at: tempRoot)
            return InstallResult(
                version: version,
                executableURL: currentExecutableURL(home: home),
                configURL: configURL(home: home)
            )
        } catch let error as InstallerError {
            try? fileManager.removeItem(at: tempRoot)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempRoot)
            throw InstallerError.decompressFailed
        }
    }

    nonisolated private static func assetName(version: String) -> String {
        #if arch(arm64)
        return "mihomo-darwin-arm64-\(version).gz"
        #else
        return "mihomo-darwin-amd64-\(version).gz"
        #endif
    }

    nonisolated private static func fetchRelease() async throws -> Release {
        let data = try await fetch(releaseAPI)
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw InstallerError.invalidReleaseResponse
        }
        return release
    }

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClayHub", forHTTPHeaderField: "User-Agent")

        // GitHub 直连在部分网络下不稳定：先直连，失败后依次尝试常见
        // 本地代理端口（包括 mihomo 自己的混合端口），全部失败才报错。
        let proxyPorts = [nil, 7890, 7891]
        var lastError: Error = InstallerError.invalidReleaseResponse
        for port in proxyPorts {
            do {
                let (data, response) = try await session(proxyPort: port).data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 指定本地代理端口的会话；port 为 nil 时走系统默认（直连）。
    nonisolated private static func session(proxyPort: Int?) -> URLSession {
        guard let proxyPort else { return URLSession.shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
            kCFStreamPropertyHTTPSProxyHost as String: "127.0.0.1",
            kCFStreamPropertyHTTPSProxyPort as String: proxyPort
        ]
        return URLSession(configuration: configuration)
    }

    /// 单文件 gzip：解出唯一的原始内容。失败时返回 nil，由调用方统一报错。
    nonisolated private static func decompressGzip(_ archiveURL: URL) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", archiveURL.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return outputPipe.fileHandleForReading.readDataToEndOfFile()
    }

    nonisolated private static func updateCurrentLink(root: URL, version: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let current = root.appendingPathComponent("current")
        let temporary = root.appendingPathComponent(".current-\(UUID().uuidString)")
        let versionRoot = root.appendingPathComponent(version, isDirectory: true)
        try fileManager.createSymbolicLink(at: temporary, withDestinationURL: versionRoot)
        if fileManager.fileExists(atPath: current.path) {
            try fileManager.removeItem(at: current)
        }
        try fileManager.moveItem(at: temporary, to: current)
    }

    /// 基础配置只写一次（文件不存在时），端口和订阅改版由 MihomoConfig 覆盖。
    nonisolated static func ensureConfiguration(home: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configDirectoryURL(home: home), withIntermediateDirectories: true)
            let config = configURL(home: home)
            if !fileManager.fileExists(atPath: config.path) {
                let yaml = [
                    MihomoConfig.managedMarkerBegin,
                    "# subscription-url: ",
                    MihomoConfig.managedMarkerEnd,
                    "",
                    "mixed-port: \(defaultPort)",
                    "bind-address: 127.0.0.1",
                    "mode: rule",
                    "log-level: info",
                    "ipv6: false",
                    "allow-lan: false",
                    "external-controller: \"\"",
                    MihomoConfig.primaryPhysicalInterface().map { "interface-name: \($0)" } ?? "",
                    "",
                    "# 下载订阅后此处生成 proxies / proxy-groups / rules，也可手工编辑"
                ].joined(separator: "\n") + "\n"
                try yaml.data(using: .utf8)!.write(to: config, options: .atomic)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: config.path
            )
        } catch {
            throw InstallerError.configurationFailed(error.localizedDescription)
        }
    }
}
