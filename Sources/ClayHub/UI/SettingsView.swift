import SwiftUI

/// 全局设置窗口：Dock 图标、菜单栏图标、app 本体开机自启。
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 440, height: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding()
    }

    private var form: some View {
        Form {
            Section("Appearance") {
                Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Text("Hiding both icons leaves no easy way to reopen the panel until the next login.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Text("Launches the ClayHub panel itself. SideClick and each MCP server have their own auto-start settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}
