import AppKit
import ApplicationServices

/// Carries out gestures: switches desktops, opens Mission Control, cycles/resizes/closes windows.
/// Everything here needs Accessibility permission for the app running this binary (your terminal).
/// All work hops to the main queue so AppKit and Accessibility calls happen on one thread.
final class SystemActions: @unchecked Sendable {
    /// A window cycle that starts within this long of the last one continues through the same list.
    static let cycleTimeout: TimeInterval = 1.5
    /// Delay between arrow presses when stepping through several desktops.
    static let stepDelay: TimeInterval = 0.05
    static let minWindowSize = CGSize(width: 300, height: 200)

    enum ZoomMethod {
        /// Fake a trackpad pinch: smooth zoom of whatever is under the mouse pointer.
        case trackpad
        /// Press ⌘+ / ⌘− in the frontmost app: zooms in steps.
        case keyboard
    }
    /// Apps that ignore trackpad pinches but zoom with ⌘+ / ⌘−. Add bundle IDs here as you find them
    /// (`osascript -e 'id of app "Name"'` prints one).
    static let keyboardZoomApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
    ]
    /// Pinch scale change per ⌘+ / ⌘− press.
    static let keyboardZoomStep = 1.15
    /// Trackpad zoom sensitivity: magnification sent per unit of pinch scale.
    static let trackpadZoomGain = 1.0

    /// Use ⌘+ / ⌘− everywhere (--zoom-keys).
    var alwaysKeyboardZoom = false
    private var zoomMethod = ZoomMethod.trackpad
    private var zoomLastScale = 1.0
    private var zoomSteps = 0

    private var cycleList: [CGWindowID] = []
    private var cycleIndex = 0
    private var lastCycle: TimeInterval = 0

    private var resizeWindow: AXUIElement?
    private var resizeStartSize = CGSize.zero
    private var resizeCenter = CGPoint.zero

    /// Asks macOS for Accessibility permission (shows the system prompt the first time).
    static func ensureAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func perform(_ gesture: Gesture) {
        DispatchQueue.main.async { [self] in
            switch gesture {
            case .swipe(4, .left): switchDesktop(forward: false)
            case .swipe(4, .right): switchDesktop(forward: true)
            case .swipe(4, .up): HotKey.missionControl.post()
            case .swipe(4, .down): HotKey.appExpose.post()
            case .swipe(_, .left): cycleWindow(forward: false)
            case .swipe(_, .right): cycleWindow(forward: true)
            case .swipe: break
            case .twirl(let clockwise): cycleWindow(forward: clockwise)
            case .zoom(.began): beginZoom()
            case .zoom(.changed(let scale)): zoom(scale: scale)
            case .zoom(.ended): endZoom()
            case .resize(.began): beginResize()
            case .resize(.changed(let scale)): resize(scale: scale)
            case .resize(.ended): resizeWindow = nil
            case .fistClose: closeFocusedWindow()
            }
        }
    }

    // MARK: - Desktops

    private func switchDesktop(forward: Bool) {
        guard let (spaces, current) = Spaces.currentDisplay() else {
            // Couldn't read the desktop list — fall back to a plain step with no wrap.
            (forward ? HotKey.nextSpace : HotKey.previousSpace).post()
            return
        }
        let atEdge = forward ? current == spaces.count - 1 : current == 0
        guard atEdge, spaces.count > 1 else {
            (forward ? HotKey.nextSpace : HotKey.previousSpace).post()
            return
        }

        // Wrap around: jump straight there with "Switch to Desktop N" if it's on, otherwise walk back.
        let target = forward ? 0 : spaces.count - 1
        if let desktopNumber = spaces[target].desktopNumber,
           let jump = HotKey.switchToDesktop(desktopNumber), jump.isEnabled {
            jump.post()
            return
        }
        let step = forward ? HotKey.previousSpace : HotKey.nextSpace
        for i in 0..<(spaces.count - 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stepDelay * Double(i)) { step.post() }
        }
    }

    // MARK: - Zoom

    private func beginZoom() {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        zoomMethod = alwaysKeyboardZoom || Self.keyboardZoomApps.contains(app) ? .keyboard : .trackpad
        zoomLastScale = 1
        zoomSteps = 0
        if zoomMethod == .trackpad { Trackpad.magnify(by: 0, phase: .began) }
    }

    private func zoom(scale: Double) {
        switch zoomMethod {
        case .trackpad:
            Trackpad.magnify(by: (scale - zoomLastScale) * Self.trackpadZoomGain, phase: .changed)
            zoomLastScale = scale
        case .keyboard:
            // One key press each time the pinch crosses another step, in or out.
            let target = Int((log(scale) / log(Self.keyboardZoomStep)).rounded(.towardZero))
            while zoomSteps < target { HotKey.press(Self.equalsKey, flags: .maskCommand); zoomSteps += 1 }
            while zoomSteps > target { HotKey.press(Self.minusKey, flags: .maskCommand); zoomSteps -= 1 }
        }
    }

    private func endZoom() {
        if zoomMethod == .trackpad { Trackpad.magnify(by: 0, phase: .ended) }
    }

    private static let equalsKey: CGKeyCode = 24
    private static let minusKey: CGKeyCode = 27

    // MARK: - Windows

    private func cycleWindow(forward: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCycle > Self.cycleTimeout || cycleList.isEmpty {
            cycleList = Self.windowsOnCurrentDesktop().map(\.id)
            cycleIndex = 0
        }
        lastCycle = now
        guard cycleList.count > 1 else { return }

        cycleIndex = (cycleIndex + (forward ? 1 : -1) + cycleList.count) % cycleList.count
        guard let window = Self.windowsOnCurrentDesktop().first(where: { $0.id == cycleList[cycleIndex] }) else {
            // Window went away since we listed them; start over next time.
            cycleList = []
            return
        }
        focus(window)
    }

    private struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    /// Normal app windows on the current desktop, front to back.
    private static func windowsOnCurrentDesktop() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 50, bounds.height > 50 else { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds)
        }
    }

    private func focus(_ window: WindowInfo) {
        let app = AXUIElementCreateApplication(window.pid)
        let axWindows: [AXUIElement] = AX.value(app, kAXWindowsAttribute) ?? []
        // Match by window ID if the private lookup is available, otherwise by position and size.
        let match = axWindows.first { AX.windowID(of: $0) == window.id }
            ?? axWindows.first { candidate in
                guard let origin = AX.point(candidate, kAXPositionAttribute),
                      let size = AX.size(candidate, kAXSizeAttribute) else { return false }
                return CGRect(origin: origin, size: size).equalTo(window.bounds)
            }
        if let match {
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    private static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = AX.value(system, kAXFocusedApplicationAttribute) else { return nil }
        return AX.value(app, kAXFocusedWindowAttribute)
    }

    private func beginResize() {
        guard let window = Self.focusedWindow(),
              let origin = AX.point(window, kAXPositionAttribute),
              let size = AX.size(window, kAXSizeAttribute) else {
            resizeWindow = nil
            return
        }
        resizeWindow = window
        resizeStartSize = size
        resizeCenter = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func resize(scale: Double) {
        guard let window = resizeWindow else { return }
        let bounds = Self.visibleBounds(containing: resizeCenter)
        var size = CGSize(width: resizeStartSize.width * scale, height: resizeStartSize.height * scale)
        size.width = min(max(size.width, Self.minWindowSize.width), bounds.width)
        size.height = min(max(size.height, Self.minWindowSize.height), bounds.height)

        // Grow/shrink around the window's center, but keep it on screen.
        var origin = CGPoint(x: resizeCenter.x - size.width / 2, y: resizeCenter.y - size.height / 2)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)

        // Size, position, size: some apps refuse a size that would hang off screen at the old position.
        AX.set(window, kAXSizeAttribute, size)
        AX.set(window, kAXPositionAttribute, origin)
        AX.set(window, kAXSizeAttribute, size)
    }

    /// The visible (menu bar and Dock excluded) frame of the screen under `point`,
    /// in Accessibility coordinates (origin top-left of the main screen).
    private static func visibleBounds(containing point: CGPoint) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        let screen = NSScreen.screens.first { flipped($0.frame).contains(point) } ?? NSScreen.main
        return screen.map { flipped($0.visibleFrame) } ?? .infinite
    }

    private func closeFocusedWindow() {
        guard let window = Self.focusedWindow(),
              let button: AXUIElement = AX.value(window, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
}

// MARK: - Keyboard shortcuts

/// A system keyboard shortcut. Reads the user's actual binding from System Settings when it can,
/// so remapped shortcuts still work.
private struct HotKey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let isEnabled: Bool

    // Arrow keys need the fn and numeric-pad flags or the Dock ignores the synthetic press.
    private static let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    // IDs from com.apple.symbolichotkeys.
    static let missionControl = HotKey(id: 32, fallbackKey: 126, fallbackFlags: arrowFlags)
    static let appExpose = HotKey(id: 33, fallbackKey: 125, fallbackFlags: arrowFlags)
    static let previousSpace = HotKey(id: 79, fallbackKey: 123, fallbackFlags: arrowFlags)
    static let nextSpace = HotKey(id: 81, fallbackKey: 124, fallbackFlags: arrowFlags)

    /// "Switch to Desktop N" (off by default; IDs 118–127 are desktops 1–10).
    static func switchToDesktop(_ number: Int) -> HotKey? {
        let digitKeys: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        guard (1...digitKeys.count).contains(number) else { return nil }
        return HotKey(id: 117 + number, fallbackKey: digitKeys[number - 1], fallbackFlags: .maskControl,
                      enabledByDefault: false)
    }

    init(id: Int, fallbackKey: CGKeyCode, fallbackFlags: CGEventFlags, enabledByDefault: Bool = true) {
        let entry = (UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")?[String(id)]) as? [String: Any]
        let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Int]
        if let parameters, parameters.count == 3 {
            keyCode = CGKeyCode(parameters[1])
            flags = CGEventFlags(rawValue: UInt64(parameters[2]))
        } else {
            keyCode = fallbackKey
            flags = fallbackFlags
        }
        isEnabled = (entry?["enabled"] as? Bool) ?? enabledByDefault
    }

    func post() {
        Self.press(keyCode, flags: flags)
    }

    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Trackpad pinch (undocumented event fields)

/// Posts the same magnify events a trackpad pinch produces. The field numbers aren't public;
/// they're the ones tools like Mac Mouse Fix use. Goes to the window under the mouse pointer.
private enum Trackpad {
    enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    private static let gestureEventType = CGEventType(rawValue: 29)!  // NSEventTypeGesture
    private static let hidTypeField = CGEventField(rawValue: 110)!
    private static let zoomHIDType: Int64 = 8  // kIOHIDEventTypeZoom
    private static let magnificationField = CGEventField(rawValue: 113)!
    private static let phaseField = CGEventField(rawValue: 132)!

    static func magnify(by amount: Double, phase: Phase) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = gestureEventType
        event.setIntegerValueField(hidTypeField, value: zoomHIDType)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        event.setDoubleValueField(magnificationField, value: amount)
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Desktop list (private CoreGraphics API)

/// macOS has no public API for the list of desktops, so this uses the same private calls
/// as tools like yabai. Looked up at runtime so a future macOS that drops them just disables wrapping.
private enum Spaces {
    struct Space {
        /// 1-based number among regular desktops; nil for full-screen app spaces.
        let desktopNumber: Int?
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        // RTLD_DEFAULT isn't imported into Swift; it's (void *)-2.
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Spaces on the display showing the active space, in order, plus the active one's index.
    static func currentDisplay() -> (spaces: [Space], current: Int)? {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self),
              let activeSpace = symbol("CGSGetActiveSpace", as: ActiveSpace.self),
              let copySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopySpaces.self) else { return nil }
        let cid = connection()
        let active = activeSpace(cid)
        guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for display in displays {
            guard let list = display["Spaces"] as? [[String: Any]] else { continue }
            let ids = list.map { ($0["ManagedSpaceID"] as? UInt64) ?? UInt64(($0["id64"] as? Int) ?? 0) }
            guard let current = ids.firstIndex(of: active) else { continue }
            var desktopCount = 0
            let spaces = list.map { space -> Space in
                // type 0 = regular desktop, 4 = full-screen app.
                guard (space["type"] as? Int) == 0 else { return Space(desktopNumber: nil) }
                desktopCount += 1
                return Space(desktopNumber: desktopCount)
            }
            return (spaces, current)
        }
        return nil
    }
}

// MARK: - Accessibility helpers

private enum AX {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var point = CGPoint.zero
        guard let value: AXValue = axValue(element, attribute),
              AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var size = CGSize.zero
        guard let value: AXValue = axValue(element, attribute),
              AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    static func set(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, attribute as CFString, value)
        }
    }

    static func set(_ element: AXUIElement, _ attribute: String, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, attribute as CFString, value)
        }
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(pointer, to: GetWindow.self)
    }()

    /// The CGWindowID behind an AX window (private API, widely used by window managers).
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success else { return nil }
        return id
    }
}
