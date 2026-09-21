import SwiftUI

/// mihomo 服务的配置面板：安装内核、订阅地址、代理端口、配置文件入口。
/// 与其它服务一样由 Services 列表里的 Enabled 开关控制启停；
/// mihomo 自身不接管系统代理、不开 TUN、无 WebUI。
struct MihomoView: View {
    @ObservedObject var mihomoInstaller = MihomoInstaller.shared
    @EnvironmentObject var mcpManager: MCPManager
    @Environment(\.dismiss) private var dismiss

    @State private var subscriptionURL = ""
    @State private var port = MihomoInstaller.defaultPort
    @State private var mode = "rule"
    @State private var portText: String
    @State private var loadedManaged = false
    @State private var isDownloading = false
    @State private var message: String?
    @State private var isError = false

    init() {
        _portText = State(initialValue: String(MihomoInstaller.defaultPort))
    }

    private var mihomoServer: MCPServerDefinition? {
        mcpManager.servers.first { $0.name == MihomoInstaller.serviceName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("mihomo 内核代理").font(.title2).bold()
                Spacer()
                Button("完成") { dismiss() }
            }

            Text("通过订阅地址在本地开启一个 HTTP/SOCKS 混合代理端口，供自由调用。不启用 TUN、不修改系统代理、无 WebUI；随 ClayHub 启停。")
                .font(.caption)
                .foregroundColor(.secondary)

            if let error = mihomoInstaller.installedVersion {
                Text("已安装内核 \(error)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                installSection
            }

            subscriptionSection

            HStack {
                Text("运行模式").font(.headline)
                Spacer()
                Picker("运行模式", selection: $mode) {
                    Text("规则").tag("rule")
                    Text("全局").tag("global")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: mode) { newValue in
                    saveManaged(port: port, subscriptionURL: subscriptionURL, mode: newValue)
                }
            }
            Text("全局：这个端口的所有流量都走代理节点（当前只有一个节点即全走它）。规则：按配置文件里的 rules 分流。")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            configSection

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(isError ? .red : .green)
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: loadManagedFields)
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                installKernel()
            } label: {
                if mihomoInstaller.isInstalling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在下载 mihomo 内核…")
                    }
                } else {
                    Text("安装 mihomo 内核")
                }
            }
            .disabled(mihomoInstaller.isInstalling)
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("订阅地址").font(.headline)
            TextField("https://example.com/subscription", text: $subscriptionURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    downloadSubscription()
                } label: {
                    if isDownloading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("下载中…")
                        }
                    } else {
                        Text("下载订阅")
                    }
                }
                .disabled(isDownloading || subscriptionURL.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if let updated = MihomoConfig.readManagedFields(home: FileManager.default.homeDirectoryForCurrentUser).subscriptionUpdatedAt {
                    Text("上次更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("代理端口").font(.headline)
                Spacer()
                TextField("端口", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                Button("应用端口") { applyPort() }
                    .disabled(!isValidPort)
            }
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配置文件").font(.headline)
            HStack(spacing: 4) {
                Button(MihomoInstaller.configURL(home: FileManager.default.homeDirectoryForCurrentUser).path) {
                    openConfigFolder()
                }
                .buttonStyle(.link)
                .help("在 Finder 中显示配置文件")
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            Text("下载订阅后配置文件会自动生成节点；你也可以点击路径直接修改 YAML，改完重启服务生效。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var isValidPort: Bool {
        guard let value = Int(portText) else { return false }
        return (1024...65535).contains(value)
    }

    // MARK: - 动作

    private func loadManagedFields() {
        let fields = MihomoConfig.readManagedFields(home: FileManager.default.homeDirectoryForCurrentUser)
        subscriptionURL = fields.subscriptionURL
        port = fields.port
        portText = String(fields.port)
        mode = fields.mode
        loadedManaged = true
    }

    private func installKernel() {
        Task { @MainActor in
            do {
                _ = try await mihomoInstaller.installLatest()
                try MihomoInstaller.ensureConfiguration(home: FileManager.default.homeDirectoryForCurrentUser)
                show(message: "mihomo 内核安装完成。", error: false)
            } catch {
                show(message: error.localizedDescription, error: true)
            }
        }
    }

    private func downloadSubscription() {
        guard !isDownloading else { return }
        let url = subscriptionURL.trimmingCharacters(in: .whitespaces)
        guard let currentPort = Int(portText), (1024...65535).contains(currentPort) else {
            show(message: "端口无效（1024–65535）。", error: true)
            return
        }
        isDownloading = true
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                let yaml = try await MihomoConfig.downloadSubscription(urlString: url)
                try MihomoConfig.applySubscription(
                    subscriptionYAML: yaml,
                    port: currentPort,
                    subscriptionURL: url,
                    mode: mode
                )
                port = currentPort
                show(message: "订阅下载成功，配置已更新。", error: false)
                restartIfRunning()
            } catch {
                show(message: error.localizedDescription, error: true)
            }
        }
    }

    private func applyPort() {
        guard let newPort = Int(portText), (1024...65535).contains(newPort) else { return }
        saveManaged(port: newPort, subscriptionURL: subscriptionURL, mode: mode)
        restartIfRunning()
    }

    private func saveManaged(port newPort: Int, subscriptionURL newURL: String, mode newMode: String) {
        do {
            try MihomoConfig.saveManagedFields(
                home: FileManager.default.homeDirectoryForCurrentUser,
                port: newPort,
                subscriptionURL: newURL,
                subscriptionUpdatedAt: nil,
                mode: newMode
            )
            port = newPort
            subscriptionURL = newURL
            portText = String(newPort)
            mode = newMode
            show(message: "已保存设置。", error: false)
            restartIfRunning()
        } catch {
            show(message: error.localizedDescription, error: true)
        }
    }

    private func restartIfRunning() {
        guard let server = mihomoServer, server.isEnabled else { return }
        mcpManager.restart(server)
    }

    private func openConfigFolder() {
        let folder = MihomoInstaller.configDirectoryURL(home: FileManager.default.homeDirectoryForCurrentUser)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([MihomoInstaller.configURL(home: FileManager.default.homeDirectoryForCurrentUser)])
    }

    private func show(message text: String, error: Bool) {
        message = text
        isError = error
    }
}
