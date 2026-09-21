import SwiftUI

@main
struct ClayHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appSettings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("ClayHub", systemImage: "square.grid.2x2.fill", isInserted: menuBarIconBinding) {
            Button("SideClick") {
                openWindow(id: "sideclick")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("MacBridge 状态与错误") {
                appDelegate.macBridgeMonitor.openDetailsWindow()
            }
            Button("Services") {
                openWindow(id: "mcp")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("SideClick", id: "sideclick") {
            ContentView()
                .environmentObject(appDelegate.bindingManager)
        }
        .windowResizability(.automatic)

        WindowGroup("Services", id: "mcp") {
            MCPManagerView()
                .environmentObject(appDelegate.mcpManager)
                .environmentObject(appDelegate.macBridgeMonitor)

        }
        .windowResizability(.automatic)
        .commandsRemoved()

        WindowGroup("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appSettings)
        }
        .windowResizability(.automatic)
    }

    /// `MenuBarExtra` may write its current insertion state back while opening
    /// a window. Avoid publishing an unchanged value, which otherwise causes
    /// the menu bar scene to rebuild and immediately write the value again.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { appSettings.showMenuBarIcon },
            set: { isInserted in
                guard appSettings.showMenuBarIcon != isInserted else { return }
                appSettings.showMenuBarIcon = isInserted
            }
        )
    }
}
