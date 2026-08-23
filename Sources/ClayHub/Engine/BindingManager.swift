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

    /// SideClick 是否启用。启用时由 ClayHub 立即启动鼠标监听，并在下次
    /// ClayHub 启动时恢复；与 app 本体是否随 macOS 登录启动相互独立。
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: enabledKey)
            onEnabledChange?(isEnabled)
        }
    }

    var onEnabledChange: ((Bool) -> Void)?

    private let defaults: UserDefaults
    private let storageKey = "ClayHubBindings"
    private let legacyStorageKey = "SideClickBindings"
    private let enabledKey = "ClayHubSideClickEnabled"
    private let legacyStartAtLaunchKey = "ClayHubSideClickStartAtLaunch"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEnabled = defaults.object(forKey: enabledKey) as? Bool
        let legacyEnabled = defaults.object(forKey: legacyStartAtLaunchKey) as? Bool
        isEnabled = storedEnabled ?? legacyEnabled ?? true
        if storedEnabled == nil {
            defaults.set(isEnabled, forKey: enabledKey)
        }
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
    }

    func requestRequiredPermissions() {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(accessibilityOptions)

        refreshPermissionStatus()
    }

    func removeBinding(for button: MouseButton) {
        bindings.removeValue(forKey: button)
        save()
    }

    private func load() {
        // 迁移：新 key 为空时，从旧 SideClick 的 key 读回，保住已有绑定
        if defaults.data(forKey: storageKey) == nil,
           let legacy = defaults.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode([MouseButton: KeyCombination].self, from: legacy) {
            bindings = decoded
            save()
            return
        }

        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                [MouseButton: KeyCombination].self, from: data
              ) else { return }
        bindings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
