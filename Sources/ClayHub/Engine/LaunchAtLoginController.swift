import Foundation
import ServiceManagement

/// 开机自启控制。优先使用 macOS 13+ 的 `SMAppService.mainApp`；
/// 因 ad-hoc 签名导致注册失败时，回退到 LaunchAgent plist。
enum LaunchAtLoginController {
    static let bundleID = "com.clayhub.app"

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return plistExists
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                return
            } catch {
                installLaunchAgent()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgent()
        }
    }

    // MARK: - LaunchAgent 回退

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    private static var plistExists: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    private static func installLaunchAgent() {
        let plist: [String: Any] = [
            "Label": bundleID,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }
        try? data.write(to: plistURL, options: .atomic)
    }

    private static func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
