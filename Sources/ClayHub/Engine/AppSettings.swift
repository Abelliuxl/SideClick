import Foundation
import AppKit

/// 全局应用设置：Dock 图标、菜单栏图标、app 本体开机自启。
///
/// 这里的「开机自启」针对的是 ClayHub 这个**管理面板**本身，
/// 与「条目」（SideClick 鼠标绑定、MCP server）各自的开机自启相互独立：
/// - SideClick 是否随启动生效 → `BindingManager.startAtLaunch`
/// - 每个 MCP server 是否随启动拉起 → `MCPServerDefinition.autoStart`
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let showDockIcon = "ClayHubShowDockIcon"
        static let showMenuBarIcon = "ClayHubShowMenuBarIcon"
    }

    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Keys.showDockIcon)
            applyActivationPolicy()
        }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            LaunchAtLoginController.setEnabled(launchAtLogin)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showDockIcon: false,
            Keys.showMenuBarIcon: true
        ])
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        launchAtLogin = LaunchAtLoginController.isEnabled
    }

    /// Dock 图标：`.regular` 显示，`.accessory` 隐藏（纯菜单栏 app）。
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}
