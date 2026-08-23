import Foundation
import CryptoKit

/// CLIProxyAPI 的本地安装与配置支持。
///
/// CLIProxyAPI 是一个普通的 HTTP API 代理，不是 MCP 服务。ClayHub 只负责
/// 下载、准备配置并托管它的生命周期；OAuth 登录仍由 CLIProxyAPI 自己完成。
@MainActor
final class CLIProxyAPIInstaller: ObservableObject {
    static let shared = CLIProxyAPIInstaller()

    nonisolated static let serviceName = "cli-proxy-api"
    nonisolated static let defaultPort = 8317

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
        case unsupportedArchitecture
        case releaseAssetNotFound
        case checksumAssetNotFound
        case checksumMissing
        case checksumMismatch
        case archiveExtractionFailed(String)
        case binaryNotFound
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyInstalling:
                return "CLIProxyAPI 正在安装或更新。"
            case .invalidReleaseResponse:
                return "无法读取 CLIProxyAPI 的最新版本信息。"
            case .unsupportedArchitecture:
                return "当前 Mac 架构暂不支持 CLIProxyAPI。"
            case .releaseAssetNotFound:
                return "最新版本没有提供当前 Mac 所需的 CLIProxyAPI 安装包。"
            case .checksumAssetNotFound:
                return "最新版本没有提供校验文件，已停止安装。"
            case .checksumMissing:
                return "校验文件中没有找到对应安装包的 SHA-256。"
            case .checksumMismatch:
                return "CLIProxyAPI 安装包校验失败，已停止安装。"
            case let .archiveExtractionFailed(message):
                return "解压 CLIProxyAPI 失败：\(message)"
            case .binaryNotFound:
                return "安装包中没有找到 cli-proxy-api 可执行文件。"
            case let .configurationFailed(message):
                return "准备 CLIProxyAPI 配置失败：\(message)"
            }
        }
    }

    /// 下载并安装最新的官方 macOS 构建，同时保留现有版本和用户配置。
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

    // MARK: - Stable paths used by the managed service definition

    nonisolated static func installRootURL(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/ClayHub", isDirectory: true)
            .appendingPathComponent("Services/CLIProxyAPI", isDirectory: true)
    }

    nonisolated static func currentExecutableURL(home: URL) -> URL {
        installRootURL(home: home)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("cli-proxy-api")
    }

    nonisolated static func configURL(home: URL) -> URL {
        home
            .appendingPathComponent(".cli-proxy-api", isDirectory: true)
            .appendingPathComponent("config.yaml")
    }

    nonisolated static func authDirectoryURL(home: URL) -> URL {
        home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
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

    nonisolated static func defaultConfiguration(home: URL, apiKey: String) -> String {
        let authPath = "~/.cli-proxy-api"
        return """
        # Managed by ClayHub. CLIProxyAPI configuration remains editable by the user.
        host: "127.0.0.1"
        port: \(defaultPort)
        auth-dir: "\(authPath)"
        api-keys:
          - "\(apiKey)"
        remote-management:
          allow-remote: false
          secret-key: ""
        """ + "\n"
    }

    // MARK: - Download and install

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

    nonisolated private static let releaseAPI = URL(
        string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest"
    )!

    nonisolated private static func performInstall(home: URL) async throws -> InstallResult {
        let release = try await fetchRelease()
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard !version.isEmpty else { throw InstallerError.invalidReleaseResponse }

        guard let asset = release.assets.first(where: { asset in
            asset.name == assetName(version: version)
                || assetNameFallbacks(version: version).contains(asset.name)
        }) else {
            throw InstallerError.releaseAssetNotFound
        }

        guard let checksumAsset = release.assets.first(where: { $0.name == "checksums.txt" }) else {
            throw InstallerError.checksumAssetNotFound
        }

        let archiveData = try await fetch(asset.browserDownloadURL)
        let checksumText = try await fetchText(checksumAsset.browserDownloadURL)
        guard let expectedChecksum = checksum(for: asset.name, in: checksumText) else {
            throw InstallerError.checksumMissing
        }
        let actualChecksum = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
            throw InstallerError.checksumMismatch
        }

        let fileManager = FileManager.default
        let root = installRootURL(home: home)
        let versionRoot = root.appendingPathComponent(version, isDirectory: true)
        let tempRoot = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = tempRoot.appendingPathComponent(asset.name)

        do {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try archiveData.write(to: archiveURL, options: .atomic)

            let extractedRoot = tempRoot.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
            try extract(archiveURL: archiveURL, destination: extractedRoot)

            guard let extractedBinary = findBinary(in: extractedRoot) else {
                throw InstallerError.binaryNotFound
            }

            try fileManager.createDirectory(at: versionRoot, withIntermediateDirectories: true)
            let installedBinary = versionRoot.appendingPathComponent("cli-proxy-api")
            if fileManager.fileExists(atPath: installedBinary.path) {
                try fileManager.removeItem(at: installedBinary)
            }
            try fileManager.copyItem(at: extractedBinary, to: installedBinary)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: installedBinary.path
            )

            try updateCurrentLink(root: root, version: version)
            try ensureConfiguration(home: home)

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
            throw InstallerError.archiveExtractionFailed(error.localizedDescription)
        }
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
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClayHub", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw InstallerError.invalidReleaseResponse
        }
        return data
    }

    nonisolated private static func fetchText(_ url: URL) async throws -> String {
        guard let text = String(data: try await fetch(url), encoding: .utf8) else {
            throw InstallerError.invalidReleaseResponse
        }
        return text
    }

    nonisolated private static func assetName(version: String) -> String {
        "CLIProxyAPI_\(version)_darwin_\(currentAssetArchitecture).tar.gz"
    }

    nonisolated private static func assetNameFallbacks(version: String) -> [String] {
        let architectures: [String]
        #if arch(arm64)
        architectures = ["aarch64", "arm64"]
        #else
        architectures = ["amd64", "x86_64"]
        #endif
        return architectures.map { "CLIProxyAPI_\(version)_darwin_\($0).tar.gz" }
    }

    nonisolated private static var currentAssetArchitecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "amd64"
        #endif
    }

    nonisolated private static func checksum(for assetName: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[1] == Substring(assetName) else { continue }
            let value = String(fields[0]).lowercased()
            guard value.count == 64,
                  value.allSatisfy({ $0.isHexDigit }) else { continue }
            return value
        }
        return nil
    }

    nonisolated private static func extract(archiveURL: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archiveURL.path, "-C", destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "tar exited with status \(process.terminationStatus)"
            throw InstallerError.archiveExtractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    nonisolated private static func findBinary(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "cli-proxy-api",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
                  values.isRegularFile == true,
                  values.isExecutable == true else { continue }
            return url
        }
        return nil
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

    nonisolated private static func ensureConfiguration(home: URL) throws {
        let fileManager = FileManager.default
        let authDirectory = authDirectoryURL(home: home)
        do {
            try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: authDirectory.path
            )

            let config = configURL(home: home)
            if !fileManager.fileExists(atPath: config.path) {
                let apiKey = "clayhub-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                try defaultConfiguration(home: home, apiKey: apiKey)
                    .data(using: .utf8)!
                    .write(to: config, options: .atomic)
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
