import SwiftUI

/// 服务管理主界面：MCP 与普通本地服务的生命周期控制、状态和日志。
struct MCPManagerView: View {
    @EnvironmentObject var mcpManager: MCPManager
    @EnvironmentObject var macBridgeMonitor: MacBridgeMonitor
    @StateObject private var cliProxyAPIInstaller = CLIProxyAPIInstaller.shared
    @State private var editorServer: MCPServerDefinition?
    @State private var showingEditor = false
    @State private var envServer: MCPServerDefinition?
    @State private var selectedID: UUID?
    @State private var cliProxyAPIError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MacBridgeCard(monitor: macBridgeMonitor)
            Divider()
            if mcpManager.servers.isEmpty {
                emptyState
            } else {
                serverList
            }
            Divider()
            logPane
        }
        .frame(width: 900, height: 680)
        .sheet(isPresented: $showingEditor) {
            MCPServerEditorView(initial: editorServer) { server in
                if mcpManager.servers.contains(where: { $0.id == server.id }) {
                    mcpManager.update(server)
                } else {
                    mcpManager.add(server)
                }
                editorServer = nil
                showingEditor = false
            }
        }
        .sheet(item: $envServer) { server in
            MCPServerEnvironmentView(server: server) { env in
                mcpManager.updateEnvironment(env, for: server)
            }
        }
        .alert(
            "CLIProxyAPI",
            isPresented: Binding(
                get: { cliProxyAPIError != nil },
                set: { if !$0 { cliProxyAPIError = nil } }
            )
        ) {
            Button("OK") { cliProxyAPIError = nil }
        } message: {
            Text(cliProxyAPIError ?? "Unknown error")
        }
    }

    private func installCLIProxyAPI(_ server: MCPServerDefinition) {
        let wasInstalled = cliProxyAPIInstaller.isInstalled
        let wasEnabled = server.isEnabled
        let shouldEnableAfterInstall = wasEnabled || !wasInstalled
        if wasEnabled {
            // The executable is replaced during an update. Stop the owned
            // process first so macOS does not keep the old binary in use.
            mcpManager.setEnabled(false, for: server.id)
        }

        Task { @MainActor in
            do {
                _ = try await cliProxyAPIInstaller.installLatest()
                if shouldEnableAfterInstall,
                   let latest = mcpManager.servers.first(where: { $0.id == server.id }),
                   !latest.isEnabled {
                    mcpManager.setEnabled(true, for: latest.id)
                }
            } catch {
                if wasEnabled,
                   let latest = mcpManager.servers.first(where: { $0.id == server.id }),
                   !latest.isEnabled {
                    mcpManager.setEnabled(true, for: latest.id)
                }
                cliProxyAPIError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Services")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                editorServer = nil
                showingEditor = true
            } label: {
                Label("Add Service", systemImage: "plus")
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No services yet")
                .font(.headline)
            Text("Click “Add Service” to manage an MCP server or local process.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverList: some View {
        List {
            ForEach(mcpManager.servers) { server in
                ServerRow(
                    server: server,
                    state: mcpManager.state(for: server.id),
                    isSelected: selectedID == server.id,
                    onEnabledChange: { mcpManager.setEnabled($0, for: server.id) },
                    onRestart: { mcpManager.restart(server) },
                    onEdit: {
                        editorServer = server
                        showingEditor = true
                    },
                    onEditEnv: {
                        envServer = server
                    },
                    onDelete: { mcpManager.remove(server) },
                    specialActionTitle: server.name == CLIProxyAPIInstaller.serviceName
                        ? (cliProxyAPIInstaller.isInstalled ? "Update" : "Install")
                        : nil,
                    specialActionDisabled: cliProxyAPIInstaller.isInstalling,
                    onSpecialAction: server.name == CLIProxyAPIInstaller.serviceName
                        ? { installCLIProxyAPI(server) }
                        : nil
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedID = server.id }
            }
        }
        .listStyle(.inset)
    }

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedID.flatMap { id in
                    mcpManager.servers.first(where: { $0.id == id })?.name
                } ?? "Log").font(.caption).fontWeight(.semibold)
                Spacer()
                Button("Clear") {
                    if let id = selectedID {
                        mcpManager.clearLog(for: id)
                    }
                }
                .font(.caption)
            }
            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
    }

    private var logText: String {
        guard let id = selectedID else { return "Select a service to view its log." }
        let log = mcpManager.state(for: id).log
        return log.isEmpty ? "(no output yet)" : String(log.suffix(8_000))
    }
}

/// 单行服务器条目。
private struct ServerRow: View {
    let server: MCPServerDefinition
    let state: MCPServerState
    let isSelected: Bool
    let onEnabledChange: (Bool) -> Void
    let onRestart: () -> Void
    let onEdit: () -> Void
    let onEditEnv: () -> Void
    let onDelete: () -> Void
    let specialActionTitle: String?
    let specialActionDisabled: Bool
    let onSpecialAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium)
                    Text(typeBadge)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(detailLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let specialActionTitle, let onSpecialAction {
                Button(specialActionTitle, action: onSpecialAction)
                    .disabled(specialActionDisabled)
                    .help("Download or update CLIProxyAPI")
            }
            HStack(spacing: 6) {
                Toggle("Enabled", isOn: Binding(
                    get: { server.isEnabled },
                    set: onEnabledChange
                ))
                .toggleStyle(.switch)
                .font(.caption)
                .help(server.isEnabled ? "Disable and stop" : "Enable and start")

                if server.isEnabled && (state.status == .running || state.status == .failed) {
                    Button(action: onRestart) { Image(systemName: "arrow.clockwise") }
                        .help("Restart")
                }
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Edit")
                Button(action: onEditEnv) { Image(systemName: "key") }
                    .help("Environment")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .help("Delete")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
    }

    private var statusColor: Color {
        switch state.status {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var detailLine: String {
        if server.kind == .local {
            if !server.url.isEmpty { return server.url }
            let commandLine = server.command + " " + server.args.joined(separator: " ")
            return commandLine.isEmpty ? "(no command)" : commandLine
        }

        switch server.transport {
        case .http, .sse:
            return server.url
        case .stdio:
            let base = server.command + " " + server.args.joined(separator: " ")
            return base.isEmpty ? "(no command)" : base
        }
    }

    private var typeBadge: String {
        server.kind == .local ? "LOCAL" : server.transport.rawValue.uppercased()
    }
}
