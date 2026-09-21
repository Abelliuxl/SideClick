import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct BridgeSnapshot: Decodable {
    struct Event: Decodable { let at: Double; let code: String }
    let version: Int
    let pid: Int32
    let startedAt: Double
    let updatedAt: Double
    let phase: String
    let lastPollAt: Double?
    let lastResultAt: Double?
    let error: String?
    let eventError: String?
    let pendingReceipts: Int
    let rejectedReceipts: Int
    let history: [Event]

    static func decode(_ data: Data) throws -> BridgeSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }

    func problem(now: Double, runningPID: Int32?) -> String? {
        guard runningPID == pid else { return "等待当前进程的状态" }
        guard version == 1 else { return "状态格式需要更新" }
        guard now - updatedAt < 20, now >= updatedAt - 5 else { return "状态更新已中断" }
        if let error { return Self.explain(error) }
        if let eventError { return "入站通知上传异常：" + Self.explain(eventError) }
        if phase == "stopped" { return "后台服务正在退出" }
        if now - (lastPollAt ?? startedAt) > 90 { return "超过 90 秒未成功领取任务或完成轮询" }
        if pendingReceipts > 0 && now - (lastResultAt ?? startedAt) > 90 {
            return "执行回执积压，等待提交"
        }
        return nil
    }

    static func explain(_ code: String) -> String {
        if code.hasPrefix("relay_http_"), let status = Int(code.dropFirst(11)) {
            switch status {
            case 401, 403: return "中转服务认证失败（HTTP \(status)）"
            case 409: return "中转拒绝回执或任务状态冲突（HTTP 409）"
            default: return "中转服务返回 HTTP \(status)"
            }
        }
        switch code {
        case "starting": return "后台服务启动"
        case "recovered", "event_recovered": return "连接已恢复"
        case "connection_error": return "网络连接失败或超时"
        case "agent_internal_error": return "桥接内部错误，请查看本机日志"
        case "receipt_rejected": return "旧回执被拒绝，已保留且不会重执行"
        default: return "未知状态"
        }
    }
}

struct BridgeAlertPolicy {
    private var faultSince: Double?
    private var notified = false

    mutating func update(state: String, now: Double, enabled: Bool) -> String? {
        if state == "failed" {
            if faultSince == nil { faultSince = now }
            if now - faultSince! >= 30 && !notified && enabled {
                notified = true
                return "failed"
            }
        } else if state == "running" {
            let shouldNotify = notified && enabled
            faultSince = nil
            notified = false
            return shouldNotify ? "recovered" : nil
        } else {
            faultSince = nil
        }
        return nil
    }
}

/// Observes the fixed LaunchAgent. Never spawns the agent or reads its secrets.
@MainActor
final class MacBridgeMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    nonisolated static let label = "com.liuxl.macbridge.agent"
    @Published var snapshot: BridgeSnapshot?
    @Published var runningPID: Int32?
    @Published var summary = "正在检查后台服务…"
    @Published var state = "checking"
    @Published var busy = false
    @Published var actionError: String?
    @Published var showingDetails = false
    @Published var notificationsEnabled = false
    @Published var notificationNote = ""
    private var detailsWindow: NSWindow?
    private var timer: Timer?
    private var refreshing = false
    private var alertPolicy = BridgeAlertPolicy()
    private var actionPendingUntil: Date?
    private var previousPID: Int32?
    private let center = UNUserNotificationCenter.current()
    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacBridge")
    }
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plist.path)
    }
    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    override init() {
        super.init()
        center.delegate = self
        notificationsEnabled = UserDefaults.standard.bool(forKey: "MacBridgeNotifications")
    }

    func startMonitoring() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if UserDefaults.standard.object(forKey: "MacBridgeNotifications") == nil && isInstalled {
            enableNotifications()
        } else if notificationsEnabled { checkNotificationPermission() }
    }

    func enableNotifications() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsEnabled = granted
                self?.notificationNote = granted ? "仅持续故障及恢复时提醒" : "系统未允许通知，可在系统设置中开启"
                UserDefaults.standard.set(granted, forKey: "MacBridgeNotifications")
            }
        }
    }

    func disableNotifications() {
        notificationsEnabled = false
        UserDefaults.standard.set(false, forKey: "MacBridgeNotifications")
    }

    private func checkNotificationPermission() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.notificationNote = settings.authorizationStatus == .authorized
                    ? "仅持续故障及恢复时提醒" : "请在系统设置中允许 ClayHub 通知"
            }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let path = Self.support.appendingPathComponent("health.json")
        DispatchQueue.global(qos: .utility).async {
            let result = Self.launchctl(["list", Self.label])
            let pid = Self.parsePID(result.1)
            let data = try? Data(contentsOf: path)
            let health = data.flatMap { try? BridgeSnapshot.decode($0) }
            DispatchQueue.main.async {
                self.refreshing = false
                self.runningPID = pid
                self.snapshot = health
                if self.actionPendingUntil != nil, let pid, pid != self.previousPID,
                   health?.pid == pid, health?.lastPollAt != nil {
                    self.actionPendingUntil = nil
                    self.busy = false
                }
                if let deadline = self.actionPendingUntil, Date() < deadline {
                    self.state = "checking"
                    self.summary = "已请求后台服务启动或重启，等待状态更新…"
                    return
                }
                if self.actionPendingUntil != nil {
                    self.actionError = "尚未确认重启完成；当前操作可能仍在执行，请查看状态后再操作。"
                }
                self.actionPendingUntil = nil
                self.busy = false
                if !self.isInstalled {
                    self.state = "stopped"; self.summary = "尚未安装 MacBridge 后台服务"
                } else if pid == nil {
                    self.state = "failed"; self.summary = "后台服务未运行"
                } else if let health {
                    if let problem = health.problem(now: Date().timeIntervalSince1970, runningPID: pid) {
                        self.state = "failed"; self.summary = problem
                    } else if health.lastPollAt == nil {
                        self.state = "checking"; self.summary = "正在连接中转服务…"
                    } else {
                        self.state = "running"; self.summary = "后台服务正常 · 中转轮询正常"
                    }
                } else {
                    self.state = "failed"; self.summary = "进程在运行，但没有可用的健康状态"
                }
                self.updateNotifications()
            }
        }
    }

    // Commands and paths are fixed; no shell, editable commands or payloads.
    func startOrRestart() {
        guard !busy else { return }
        busy = true
        actionError = nil
        previousPID = runningPID
        actionPendingUntil = Date().addingTimeInterval(60)
        let target = "gui/\(getuid())/\(Self.label)"
        let plistPath = Self.plist.path
        DispatchQueue.global(qos: .utility).async {
            let loaded = Self.launchctl(["list", Self.label])
            let args: [String]
            if loaded.0 == 0 {
                // SIGTERM lets an in-flight operation finish and journal its result.
                args = Self.parsePID(loaded.1) == nil ? ["kickstart", target] : ["kill", "SIGTERM", target]
            } else {
                args = ["bootstrap", "gui/\(getuid())", plistPath]
            }
            let result = Self.launchctl(args)
            DispatchQueue.main.async {
                if result.0 != 0 {
                    self.busy = false
                    self.actionError = "后台服务操作失败（launchctl \(result.0)），请查看系统服务配置。"
                    self.actionPendingUntil = nil
                }
                self.refresh()
            }
        }
    }

    nonisolated static func parsePID(_ output: String) -> Int32? {
        for line in output.components(separatedBy: .newlines) where line.contains("\"PID\"") {
            let digits = line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let pid = Int32(digits), pid > 0 { return pid }
        }
        return nil
    }

    nonisolated private static func launchctl(_ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            // Bound external command lifetime so a stuck launchctl never stalls monitoring.
            let deadline = Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate(); return (-1, "") }
            return (process.terminationStatus,
                    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        } catch { return (-1, "") }
    }

    private func updateNotifications() {
        let event = alertPolicy.update(state: state, now: Date().timeIntervalSince1970,
                                       enabled: notificationsEnabled)
        if event == "failed" { notify(title: "MacBridge 连接异常", body: summary) }
        if event == "recovered" { notify(title: "MacBridge 已恢复", body: "后台服务已恢复正常轮询。") }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        center.add(UNNotificationRequest(identifier: "macbridge-status", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.openDetailsWindow()
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func openDetailsWindow() {
        if detailsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacBridge 状态与错误"
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: MacBridgeDetails(
                monitor: self, onClose: { [weak window] in window?.close() }))
            host.sizingOptions = []
            window.contentViewController = host
            window.center()
            detailsWindow = window
        }
        detailsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openLogFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacBridge"))
    }
}
