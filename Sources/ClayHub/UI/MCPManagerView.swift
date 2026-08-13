import SwiftUI

/// MCP 管理器主界面：服务器列表、启停控制、日志、开机自启开关。
struct MCPManagerView: View {
    @EnvironmentObject var mcpManager: MCPManager
    @State private var editorServer: MCPServerDefinition?
    @State private var showingEditor = false
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mcpManager.servers.isEmpty {
                emptyState
            } else {
                serverList
            }
            Divider()
            logPane
        }
        .frame(minWidth: 760, minHeight: 520)
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
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("MCP Servers")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Toggle("Launch at login", isOn: Binding(
                get: { mcpManager.launchAtLogin },
                set: { _ in mcpManager.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.switch)
            Button {
                editorServer = nil
                showingEditor = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No MCP servers yet")
                .font(.headline)
            Text("Click “Add Server” to add one, or manage local processes here.")
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
                    onStart: { mcpManager.start(server) },
                    onStop: { mcpManager.stop(server) },
                    onRestart: { mcpManager.restart(server) },
                    onEdit: {
                        editorServer = server
                        showingEditor = true
                    },
                    onDelete: { mcpManager.remove(server) }
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
        guard let id = selectedID else { return "Select a server to view its log." }
        let log = mcpManager.state(for: id).log
        return log.isEmpty ? "(no output yet)" : log
    }
}

/// 单行服务器条目。
private struct ServerRow: View {
    let server: MCPServerDefinition
    let state: MCPServerState
    let isSelected: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium)
                    Text(server.transport.rawValue.uppercased())
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
            HStack(spacing: 6) {
                if state.status == .running || state.status == .starting {
                    Button(action: onStop) { Image(systemName: "stop.fill") }
                        .help("Stop")
                    Button(action: onRestart) { Image(systemName: "arrow.clockwise") }
                        .help("Restart")
                } else {
                    Button(action: onStart) { Image(systemName: "play.fill") }
                        .help("Start")
                }
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Edit")
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
        switch server.transport {
        case .http, .sse:
            return server.url
        case .stdio:
            let base = server.command + " " + server.args.joined(separator: " ")
            return base.isEmpty ? "(no command)" : base
        }
    }
}
