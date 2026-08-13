import SwiftUI

/// 环境变量（API key / token）编辑窗口：一个文本框，每行一个 `KEY=VALUE`。
/// 保存后写入 app 内的配置，不会污染系统环境变量。
struct MCPServerEnvironmentView: View {
    let server: MCPServerDefinition
    let onSave: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(server: MCPServerDefinition, onSave: @escaping ([String: String]) -> Void) {
        self.server = server
        self.onSave = onSave
        _text = State(initialValue: MCPServerDefinition.envText(fromDict: server.env))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Environment — \(server.name)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("每行一个环境变量，格式 `KEY=VALUE`（例如 EXA_API_KEY=xxx）。保存在 app 内，不会写入系统环境。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(MCPServerDefinition.envDict(fromText: text))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 340)
    }
}
