import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let bindingManager = BindingManager()
    let mcpManager = MCPManager()
    private let keySimulator = KeySimulator()
    private var mouseMonitor: MouseEventMonitor?
    private var monitorRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestRequiredPermissions()
        startMouseMonitoring()
        mcpManager.startAutoStartServices()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [bindingManager] in
            bindingManager.requestInputMonitoringPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mcpManager.stopAll()
    }

    private func requestRequiredPermissions() {
        bindingManager.requestRequiredPermissions()
    }

    private func startMouseMonitoring() {
        mouseMonitor?.stop()

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

        let started = monitor.start()
        mouseMonitor = monitor
        if !started {
            scheduleMonitorRetryIfNeeded()
        }
    }

    /// 权限未授予时每 2 秒检测一次，一旦用户在系统设置里授权（或手动 + 添加），
    /// 就自动重建事件 tap，无需重启 app。
    private func scheduleMonitorRetryIfNeeded() {
        guard monitorRetryTimer == nil else { return }
        monitorRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if CGPreflightListenEventAccess() {
                timer.invalidate()
                self.monitorRetryTimer = nil
                self.startMouseMonitoring()
                self.bindingManager.refreshPermissionStatus()
            }
        }
    }
}
