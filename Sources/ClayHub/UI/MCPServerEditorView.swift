import SwiftUI

/// 新增 / 编辑受管服务的表单。
struct MCPServerEditorView: View {
    let initial: MCPServerDefinition?
    let onSave: (MCPServerDefinition) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: ManagedServiceKind = .mcp
    @State private var transport: MCPTransport = .http
    @State private var url = ""
    @State private var headersText = ""
    @State private var runLocally = false
    @State private var command = ""
    @State private var argsText = ""
    @State private var envText = ""
    @State private var cwd = ""
    @State private var healthURL = ""
    @State private var isEnabled = false

    init(initial: MCPServerDefinition?, onSave: @escaping (MCPServerDefinition) -> Void) {
        self.initial = initial
        self.onSave = onSave
        if let initial {
            _name = State(initialValue: initial.name)
            _kind = State(initialValue: initial.kind)
            _transport = State(initialValue: initial.transport)
            _url = State(initialValue: initial.url)
            _headersText = State(initialValue: Self.dictToText(initial.headers))
            _runLocally = State(initialValue: initial.runsLocalProcess)
            _command = State(initialValue: initial.command)
            _argsText = State(initialValue: initial.args.joined(separator: "\n"))
            _envText = State(initialValue: Self.dictToEnv(initial.env))
            _cwd = State(initialValue: initial.cwd)
            _healthURL = State(initialValue: initial.healthURL)
            _isEnabled = State(initialValue: initial.isEnabled)
        }
    }

    private var isLocalService: Bool { kind == .local }
    private var isStdio: Bool { !isLocalService && transport == .stdio }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(initial == nil ? "Add Service" : "Edit Service")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Service") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(ManagedServiceKind.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    if !isLocalService {
                        Picker("Transport", selection: $transport) {
                            ForEach(MCPTransport.allCases, id: \.self) { type in
                                Text(type.rawValue.uppercased()).tag(type)
                            }
                        }
                    }
                }

                if isLocalService {
                    Section("Endpoint") {
                        TextField("Service URL", text: $url)
                    }
                    Section("Process") {
                        processFields
                    }
                } else if isStdio {
                    Section("Process") {
                        processFields
                    }
                } else {
                    Section("Endpoint") {
                        TextField("URL", text: $url)
                        labeledEditor("Headers (one per line, `Key: Value`)", text: $headersText, height: 60)
                    }
                    Section("Process") {
                        Toggle("Run as local process", isOn: $runLocally)
                        if runLocally {
                            processFields
                        }
                    }
                }

                Section("Behavior") {
                    Toggle("Enabled", isOn: $isEnabled)
                    Text("Enabled services start and stop together with ClayHub.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 600)
    }

    private var processFields: some View {
        Group {
            TextField("Command", text: $command)
            labeledEditor("Arguments (one per line)", text: $argsText, height: 70)
            labeledEditor("Environment (one per line, `KEY=VALUE`)", text: $envText, height: 70)
            TextField("Working directory (optional)", text: $cwd)
            if !isStdio {
                TextField("Health check URL (optional)", text: $healthURL)
            }
        }
    }

    private func labeledEditor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let local = isLocalService || isStdio || runLocally
        let savedTransport: MCPTransport = isLocalService ? .http : transport

        let server = MCPServerDefinition(
            id: initial?.id ?? UUID(),
            name: trimmedName,
            kind: kind,
            transport: savedTransport,
            url: isStdio ? "" : url.trimmingCharacters(in: .whitespaces),
            headers: (isStdio || isLocalService) ? [:] : Self.textToDict(headersText),
            command: local ? command.trimmingCharacters(in: .whitespaces) : "",
            args: local ? Self.textToLines(argsText) : [],
            env: local ? Self.textToEnv(envText) : [:],
            cwd: local ? cwd.trimmingCharacters(in: .whitespaces) : "",
            isEnabled: isEnabled,
            healthURL: (local && !isStdio) ? healthURL.trimmingCharacters(in: .whitespaces) : ""
        )
        onSave(server)
        dismiss()
    }

    // MARK: - 文本 <-> 结构转换

    private static func textToLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func textToDict(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let idx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<idx].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func dictToText(_ dict: [String: String]) -> String {
        dict.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private static func textToEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let idx = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<idx].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func dictToEnv(_ dict: [String: String]) -> String {
        dict.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}
