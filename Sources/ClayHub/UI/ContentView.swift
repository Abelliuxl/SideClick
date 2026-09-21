import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bindingManager: BindingManager
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            permissionStatus
            detectedButton
            bindingList
            Spacer()
            footer
        }
        .padding()
        .frame(width: 620, height: 450)
        .onAppear { bindingManager.refreshPermissionStatus() }
        .onReceive(permissionTimer) { _ in bindingManager.refreshPermissionStatus() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mouse.fill")
                .font(.title)
                .foregroundColor(.accentColor)
            Text("SideClick")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Toggle("Enabled", isOn: $bindingManager.isEnabled)
                .toggleStyle(.switch)
                .font(.caption)
        }
    }

    private var permissionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusText("辅助功能", bindingManager.accessibilityTrusted)
                Spacer()
                Button(bindingManager.accessibilityTrusted ? "管理辅助功能权限" : "开启辅助功能权限") {
                    openAccessibilitySettings()
                }
            }
            if !bindingManager.accessibilityTrusted {
                Text("仅需辅助功能权限。如果系统开关已开但这里仍未授权，请移除旧 ClayHub 条目，再添加 /Applications/ClayHub.app。授权后会自动更新。")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    private func statusText(_ title: String, _ granted: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text("\(title): \(granted ? "已授权" : "当前 App 未获授权")")
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }

        NSWorkspace.shared.open(url)
    }

    private var detectedButton: some View {
        HStack {
            Text("Last detected:")
                .foregroundColor(.secondary)
            Text(bindingManager.lastDetectedButton?.displayName ?? "Press a side button")
                .fontWeight(.medium)
            Spacer()
            if let button = bindingManager.lastDetectedButton {
                Button("Add Binding") {
                    bindingManager.ensureBinding(for: button)
                }
                .disabled(bindingManager.bindings[button] != nil)
            }
        }
        .font(.caption)
    }

    private var triggerStatus: some View {
        HStack {
            Text("Last triggered:")
                .foregroundColor(.secondary)
            Text(bindingManager.lastTriggeredShortcut ?? "None")
                .fontWeight(.medium)
            Spacer()
        }
        .font(.caption)
    }

    private var bindingList: some View {
        VStack(spacing: 16) {
            triggerStatus
            ForEach(displayedButtons, id: \.self) { button in
                BindingRow(
                    button: button,
                    combination: Binding(
                        get: { bindingManager.bindings[button] ?? defaultBinding(for: button) },
                        set: { bindingManager.setBinding($0, for: button) }
                    )
                )
            }
        }
    }

    private var displayedButtons: [MouseButton] {
        var buttons = Set(bindingManager.bindings.keys)
        buttons.insert(.sideBack)
        buttons.insert(.sideForward)
        if let lastDetectedButton = bindingManager.lastDetectedButton {
            buttons.insert(lastDetectedButton)
        }
        return buttons.sorted()
    }

    private var footer: some View {
        Text("Requires Accessibility permission")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func defaultBinding(for button: MouseButton) -> KeyCombination {
        if button == .sideBack {
            return KeyCombination(keyCode: 2, modifiers: [.command])
        }
        if button == .sideForward {
            return KeyCombination(keyCode: 15, modifiers: [.command])
        }
        return KeyCombination(keyCode: 124, modifiers: [.control])
    }
}
