import Foundation

struct MouseButton: RawRepresentable, Codable, Hashable, Identifiable, Comparable {
    let rawValue: Int

    static let left = MouseButton(rawValue: 0)
    static let right = MouseButton(rawValue: 1)
    static let middle = MouseButton(rawValue: 2)
    static let sideBack = MouseButton(rawValue: 3)
    static let sideForward = MouseButton(rawValue: 4)

    var id: Int {
        rawValue
    }

    static func < (lhs: MouseButton, rhs: MouseButton) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .left:       return "Left Button"
        case .right:      return "Right Button"
        case .middle:     return "Middle Button"
        case .sideBack:   return "Side Button (Back)"
        case .sideForward:return "Side Button (Forward)"
        default:          return "Mouse Button \(rawValue)"
        }
    }
}
