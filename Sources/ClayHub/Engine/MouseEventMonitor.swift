import Cocoa
import CoreGraphics

class MouseEventMonitor {
    var onButtonEvent: ((MouseButton, CGEventType) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 触发系统把本 app 登记到「输入监控」列表：
    /// 显式请求权限，并创建一个临时 listen-only 事件 tap（这是让条目出现在
    /// 设置面板里的经典手段），随后立即销毁。
    static func primeInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, _, _ in nil },
            userInfo: nil
        ) {
            CFMachPortInvalidate(tap)
        }
    }

    @discardableResult
    func start() -> Bool {
        let eventMask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                let monitor = Unmanaged<MouseEventMonitor>
                    .fromOpaque(refcon!)
                    .takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Grant Input Monitoring permission in System Settings.")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let button = MouseButton(rawValue: Int(buttonNumber))
        guard button.rawValue >= MouseButton.sideBack.rawValue else {
            return Unmanaged.passUnretained(event)
        }

        let handled = onButtonEvent?(button, type) ?? false
        return handled ? nil : Unmanaged.passUnretained(event)
    }
}
