import XCTest
@testable import ClayHub

final class ClayHubTests: XCTestCase {
    func testMouseButtonRawValues() {
        XCTAssertEqual(MouseButton.left.rawValue, 0)
        XCTAssertEqual(MouseButton.right.rawValue, 1)
        XCTAssertEqual(MouseButton.middle.rawValue, 2)
        XCTAssertEqual(MouseButton.sideBack.rawValue, 3)
        XCTAssertEqual(MouseButton.sideForward.rawValue, 4)
        XCTAssertEqual(MouseButton(rawValue: 8).displayName, "Mouse Button 8")
    }

    func testKeyCombinationEquality() {
        let a = KeyCombination(keyCode: 2, modifiers: [.command])
        let b = KeyCombination(keyCode: 2, modifiers: [.command])
        let c = KeyCombination(keyCode: 2, modifiers: [.command, .shift])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testModifierFlagsDisplay() {
        let flags: KeyCombination.ModifierFlags = [.command, .shift]
        XCTAssertTrue(flags.displayString.contains("⌘"))
        XCTAssertTrue(flags.displayString.contains("⇧"))
    }

    func testModifierKeyEvents() {
        let flags: KeyCombination.ModifierFlags = [.control, .command]
        let keyEvents = flags.keyEvents

        XCTAssertEqual(keyEvents.map(\.keyCode), [59, 55])
    }

    func testArrowKeyDisplayNames() {
        XCTAssertEqual(KeyCombination(keyCode: 123, modifiers: [.control]).displayName, "⌃Left")
        XCTAssertEqual(KeyCombination(keyCode: 124, modifiers: [.control]).displayName, "⌃Right")
    }

    func testBindingManagerPersistence() {
        let manager = BindingManager()
        let combo = KeyCombination(keyCode: 2, modifiers: [.command])
        manager.setBinding(combo, for: .sideBack)
        XCTAssertEqual(manager.binding(for: .sideBack), combo)
    }
}
