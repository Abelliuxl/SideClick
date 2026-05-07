import SwiftUI

@main
struct SideClickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("SideClick", systemImage: "computermouse.fill") {
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

        WindowGroup("Settings", id: "settings") {
            ContentView()
                .environmentObject(appDelegate.bindingManager)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}
