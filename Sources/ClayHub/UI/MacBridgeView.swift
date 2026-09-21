import SwiftUI

struct MacBridgeCard: View {
    @ObservedObject var monitor: MacBridgeMonitor
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("MacBridge").fontWeight(.semibold)
                    Text("后台常驻").font(.caption).foregroundColor(.secondary)
                }
                Text(monitor.summary).font(.caption)
                Text("关闭 ClayHub 后仍运行").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button("查看状态与错误") { monitor.showingDetails = true }
            Button(monitor.runningPID == nil ? "启动" : "重启") { monitor.startOrRestart() }
                .disabled(monitor.busy || !monitor.isInstalled)
        }
        .padding()
        .background(color.opacity(0.06))
        .sheet(isPresented: $monitor.showingDetails) { MacBridgeDetails(monitor: monitor) }
    }
    private var color: Color {
        switch monitor.state {
        case "running": return .green
        case "failed": return .red
        case "stopped": return .gray
        default: return .orange
        }
    }
}

struct MacBridgeDetails: View {
    @ObservedObject var monitor: MacBridgeMonitor
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MacBridge 状态与错误").font(.title2).bold()
                Spacer()
                Button("完成") { if let onClose { onClose() } else { dismiss() } }
            }
            Text(monitor.summary).font(.headline)
            Text("监控 Mac 后台服务与中转连接；不代表 Ubuntu OpenClaw 或消息最终送达状态。")
                .font(.caption).foregroundColor(.secondary)
            if let s = monitor.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow { Text("后台进程"); Text(monitor.runningPID.map(String.init) ?? "未运行") }
                    GridRow { Text("状态更新"); Text(date(s.updatedAt)) }
                    GridRow { Text("最近成功轮询"); Text(date(s.lastPollAt)) }
                    GridRow { Text("最近回执提交"); Text(date(s.lastResultAt)) }
                    GridRow { Text("待提交回执"); Text("\(s.pendingReceipts)") }
                    GridRow { Text("已保留的拒绝回执"); Text("\(s.rejectedReceipts)") }
                }.font(.callout)
                if s.rejectedReceipts > 0 {
                    Text("被拒绝的旧回执仅保留供核对，不会自动重执行；它们不阻塞新任务。")
                        .font(.caption).foregroundColor(.orange)
                }
                Divider()
                Text("最近诊断记录").bold()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(s.history.reversed().enumerated()), id: \.offset) { _, event in
                            Text("\(date(event.at))  \(BridgeSnapshot.explain(event.code))")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 100, maxHeight: 180)
            } else {
                Text("尚无健康状态。服务启动后会自动更新。")
            }
            if let error = monitor.actionError { Text(error).foregroundColor(.red) }
            Divider()
            Toggle("持续故障时通知我（30 秒后提醒，恢复时再提醒）", isOn: Binding(
                get: { monitor.notificationsEnabled },
                set: { if $0 { monitor.enableNotifications() } else { monitor.disableNotifications() } }
            ))
            if !monitor.notificationNote.isEmpty {
                Text(monitor.notificationNote).font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button("打开本机日志文件夹") { monitor.openLogFolder() }
                Button("刷新") { monitor.refresh() }
                Spacer()
                Button(monitor.runningPID == nil ? "启动后台服务" : "重启后台服务") { monitor.startOrRestart() }
                    .disabled(monitor.busy || !monitor.isInstalled)
            }
            Text("重启会等待正在执行的操作结束，不会重发历史消息。诊断面板不读取密钥或消息内容。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 640, height: 600)
    }
    private func date(_ timestamp: Double?) -> String {
        guard let timestamp else { return "尚无记录" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .standard)
    }
}
