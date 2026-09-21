import Cocoa
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let bindingManager = BindingManager()
    let mcpManager = MCPManager()
    let macBridgeMonitor = MacBridgeMonitor()
    private let keySimulator = KeySimulator()
    private var mouseMonitor: MouseEventMonitor?
    private var monitorRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyActivationPolicy()
        bindingManager.onEnabledChange = { [weak self] isEnabled in
            guard let self else { return }
            if isEnabled {
                self.startSideClick()
            } else {
                self.stopSideClick()
            }
        }
        if bindingManager.isEnabled {
            startSideClick()
        }
        mcpManager.startEnabledServices()
        macBridgeMonitor.startMonitoring()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        macBridgeMonitor.openDetailsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSideClick()
        mcpManager.stopAll()
    }

    private func requestRequiredPermissions() {
        bindingManager.requestRequiredPermissions()
    }

    private func startSideClick() {
        guard bindingManager.isEnabled else { return }
        requestRequiredPermissions()
        startMouseMonitoring()
    }

    private func stopSideClick() {
        monitorRetryTimer?.invalidate()
        monitorRetryTimer = nil
        mouseMonitor?.stop()
        mouseMonitor = nil
    }

    private func startMouseMonitoring() {
        guard bindingManager.isEnabled else { return }
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

    /// 权限未授予时每 2 秒检测一次，一旦用户在系统设置里授权，
    /// 就自动重建事件 tap，无需重启 app。
    private func scheduleMonitorRetryIfNeeded() {
        guard monitorRetryTimer == nil else { return }
        monitorRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if !self.bindingManager.isEnabled {
                    timer.invalidate()
                    self.monitorRetryTimer = nil
                } else if AXIsProcessTrusted() {
                    timer.invalidate()
                    self.monitorRetryTimer = nil
                    self.startMouseMonitoring()
                    self.bindingManager.refreshPermissionStatus()
                }
            }
        }
    }
}
