import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let bindingManager = BindingManager()
    let mcpManager = MCPManager()
    private let keySimulator = KeySimulator()
    private var mouseMonitor: MouseEventMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestRequiredPermissions()
        startMouseMonitoring()
        mcpManager.startAutoStartServices()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [bindingManager] in
            bindingManager.requestInputMonitoringPermission()
        }
    }

    private func requestRequiredPermissions() {
        bindingManager.requestRequiredPermissions()
    }

    private func startMouseMonitoring() {
        let monitor = MouseEventMonitor()
        monitor.onButtonEvent = { [weak self] button, type in
            guard let self else { return false }
            let combo = self.bindingManager.binding(for: button)

            if type == .otherMouseDown {
                DispatchQueue.main.async { [self] in
                    self.bindingManager.lastDetectedButton = button
                    guard let combo else { return }
                    self.bindingManager.refreshPermissionStatus()
                    self.bindingManager.lastTriggeredShortcut = "\(button.displayName) -> \(combo.displayName)"
                    self.keySimulator.simulate(combo)
                }
            }

            return combo != nil
        }
        monitor.start()
        mouseMonitor = monitor
    }
}
