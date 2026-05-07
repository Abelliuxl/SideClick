import SwiftUI

struct BindingRow: View {
    let button: MouseButton
    @Binding var combination: KeyCombination

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 14) {
            Text(button.displayName)
                .frame(width: 160, alignment: .leading)
            Spacer()

            modifierToggle("Ctrl", .control)
            modifierToggle("Cmd", .command)
            modifierToggle("Opt", .option)
            modifierToggle("Shift", .shift)

            Button(action: startRecording) {
                Text(isRecording ? "Press key" : combination.keyDisplayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 82, height: 24)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func modifierToggle(
        _ title: String,
        _ flag: KeyCombination.ModifierFlags
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { combination.modifiers.contains(flag) },
            set: { isOn in
                if isOn {
                    combination.modifiers.insert(flag)
                } else {
                    combination.modifiers.remove(flag)
                }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .frame(width: 58, alignment: .leading)
    }

    private func startRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }

        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let newCombo = KeyCombination(
                keyCode: event.keyCode,
                modifiers: self.combination.modifiers
            )
            DispatchQueue.main.async {
                self.combination = newCombo
                self.isRecording = false
                if let m = self.monitor {
                    NSEvent.removeMonitor(m)
                    self.monitor = nil
                }
            }
            return nil
        }
    }
}
