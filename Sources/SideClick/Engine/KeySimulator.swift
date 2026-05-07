import Cocoa
import CoreGraphics

class KeySimulator {
    private let modifierLeadTime: TimeInterval = 0.001
    private let keyHoldTime: TimeInterval = 0.12
    private let releaseGap: TimeInterval = 0.001

    func simulate(_ combination: KeyCombination) {
        let source = CGEventSource(stateID: CGEventSourceStateID(rawValue: -1)!)
        source?.localEventsSuppressionInterval = 0
        let modifiers = combination.modifiers.keyEvents

        for modifier in modifiers {
            postKey(source: source, keyCode: modifier.keyCode, keyDown: true)
            Thread.sleep(forTimeInterval: modifierLeadTime)
        }

        postKey(source: source, keyCode: combination.keyCode, keyDown: true)
        Thread.sleep(forTimeInterval: keyHoldTime)
        postKey(source: source, keyCode: combination.keyCode, keyDown: false)

        Thread.sleep(forTimeInterval: releaseGap)

        for modifier in modifiers.reversed() {
            postKey(source: source, keyCode: modifier.keyCode, keyDown: false)
            Thread.sleep(forTimeInterval: releaseGap)
        }
    }

    private func postKey(
        source: CGEventSource?,
        keyCode: UInt16,
        keyDown: Bool
    ) {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return }

        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.post(tap: .cgSessionEventTap)
    }
}
