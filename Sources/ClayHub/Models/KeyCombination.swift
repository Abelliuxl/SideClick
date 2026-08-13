import Cocoa
import CoreGraphics

struct KeyCombination: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: ModifierFlags

    struct ModifierFlags: OptionSet, Codable, Equatable {
        let rawValue: Int

        static let command = ModifierFlags(rawValue: 1 << 0)
        static let option  = ModifierFlags(rawValue: 1 << 1)
        static let control = ModifierFlags(rawValue: 1 << 2)
        static let shift   = ModifierFlags(rawValue: 1 << 3)

        var displayString: String {
            var parts: [String] = []
            if contains(.control) { parts.append("⌃") }
            if contains(.option)  { parts.append("⌥") }
            if contains(.shift)   { parts.append("⇧") }
            if contains(.command) { parts.append("⌘") }
            return parts.joined()
        }

        var cgEventFlags: CGEventFlags {
            var flags = CGEventFlags()
            if contains(.command) { flags.insert(.maskCommand) }
            if contains(.option)  { flags.insert(.maskAlternate) }
            if contains(.control) { flags.insert(.maskControl) }
            if contains(.shift)   { flags.insert(.maskShift) }
            return flags
        }

        var keyEvents: [(keyCode: UInt16, flag: CGEventFlags)] {
            var events: [(keyCode: UInt16, flag: CGEventFlags)] = []
            if contains(.control) { events.append((keyCode: 59, flag: .maskControl)) }
            if contains(.option)  { events.append((keyCode: 58, flag: .maskAlternate)) }
            if contains(.shift)   { events.append((keyCode: 56, flag: .maskShift)) }
            if contains(.command) { events.append((keyCode: 55, flag: .maskCommand)) }
            return events
        }
    }

    var displayName: String {
        modifiers.displayString + keyName
    }

    var keyDisplayName: String {
        keyName
    }

    var isControlArrowShortcut: Bool {
        modifiers == [.control] && [123, 124, 125, 126].contains(keyCode)
    }

    private var keyName: String {
        switch keyCode {
        case 0:   return "A"
        case 1:   return "S"
        case 2:   return "D"
        case 3:   return "F"
        case 4:   return "H"
        case 5:   return "G"
        case 6:   return "Z"
        case 7:   return "X"
        case 8:   return "C"
        case 9:   return "V"
        case 11:  return "B"
        case 12:  return "Q"
        case 13:  return "W"
        case 14:  return "E"
        case 15:  return "R"
        case 16:  return "Y"
        case 17:  return "T"
        case 31:  return "O"
        case 32:  return "U"
        case 34:  return "I"
        case 35:  return "P"
        case 37:  return "L"
        case 38:  return "J"
        case 40:  return "K"
        case 45:  return "N"
        case 46:  return "M"
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 53:  return "Esc"
        case 51:  return "Delete"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default:  return "Key(\(keyCode))"
        }
    }
}
