import SwiftUI

@main
struct ClayHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("ClayHub", systemImage: "computermouse.fill") {
            Button("Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("MCP Servers") {
                openWindow(id: "mcp")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Settings", id: "settings") {
            ContentView()
                .environmentObject(appDelegate.bindingManager)
        }
        .windowResizability(.contentSize)

        WindowGroup("MCP Servers", id: "mcp") {
            MCPManagerView()
                .environmentObject(appDelegate.mcpManager)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}
