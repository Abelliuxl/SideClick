import Foundation
import ApplicationServices
import CoreGraphics

class BindingManager: ObservableObject {
    @Published var bindings: [MouseButton: KeyCombination] = [
        .sideBack: KeyCombination(keyCode: 2, modifiers: [.command]),      // ⌘D
        .sideForward: KeyCombination(keyCode: 15, modifiers: [.command]),  // ⌘R
    ]
    @Published var lastDetectedButton: MouseButton?
    @Published var lastTriggeredShortcut: String?
    @Published var accessibilityTrusted = false
    @Published var inputMonitoringTrusted = false

    private let storageKey = "SideClickBindings"

    init() {
        load()
        refreshPermissionStatus()
    }

    func binding(for button: MouseButton) -> KeyCombination? {
        bindings[button]
    }

    func setBinding(_ combination: KeyCombination, for button: MouseButton) {
        bindings[button] = combination
        save()
    }

    func ensureBinding(for button: MouseButton) {
        guard bindings[button] == nil else { return }
        bindings[button] = KeyCombination(keyCode: 124, modifiers: [.control])
        save()
    }

    func refreshPermissionStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringTrusted = CGPreflightListenEventAccess()
    }

    func requestRequiredPermissions() {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(accessibilityOptions)

        requestInputMonitoringPermission()
        refreshPermissionStatus()
    }

    func requestInputMonitoringPermission() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshPermissionStatus()
        }
    }

    func removeBinding(for button: MouseButton) {
        bindings.removeValue(forKey: button)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                [MouseButton: KeyCombination].self, from: data
              ) else { return }
        bindings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
