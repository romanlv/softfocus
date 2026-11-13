import AppKit
import ApplicationServices
import Testing
import SoftfocusCore

/// Opens Settings the way a user does: from the menu-bar icon, while another app is in front.
extension EndToEndTests {
    @Test(.enabled(if: ScreenState.canDriveUI, "needs an unlocked screen, Accessibility access and no other Softfocus rest on screen"))
    func settingsOpensFromMenuBarOnFirstTry() throws {
        let app = try RunningApp(settings: quickSettings(work: 600))
        defer { app.stop() }
        let ax = AXDriver(pid: app.pid)
        // Another app is in front, as when the user is working.
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        finder.activate()
        #expect(eventually(timeout: 3) { AXDriver.focusedAppPID == finder.processIdentifier })

        try ax.chooseFromStatusMenu("Settings…")
        let isMain = { ax.window(SettingsID.window).map { AXDriver.attr($0, kAXMainAttribute) as? Bool == true } == true }
        let shown = eventually(timeout: 3) { AXDriver.focusedAppPID == app.pid && isMain() }
        let front = AXDriver.focusedAppPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
        #expect(shown, "Settings should be in front after one click; \(front) is in front, Settings main: \(isMain())")

        // Closing Settings puts the app back in the menu bar only.
        try ax.closeWindow(SettingsID.window)
        try app.waitFor("menu bar only") { _, ui in !ui.settingsWindowVisible && ui.activationPolicy == "accessory" }
    }
}

extension AXDriver {
    /// Clicks a window's close button.
    func closeWindow(_ identifier: String) throws {
        guard let w = window(identifier), let button = Self.attr(w, kAXCloseButtonAttribute) else {
            throw HarnessError("no close button on \(identifier)")
        }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// The app that has the keyboard focus right now. (NSWorkspace's answer goes stale
    /// in a test process, which never runs its run loop.)
    static var focusedAppPID: pid_t? {
        guard let app = attr(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app as! AXUIElement, &pid) == .success ? pid : nil
    }

    /// Opens the app's menu-bar menu and clicks an item with the real mouse, because macOS
    /// only lets an app take the focus after a genuine click. The menu is opened through
    /// accessibility, since a new icon can sit hidden under the camera notch.
    func chooseFromStatusMenu(_ title: String) throws {
        guard let bar = Self.attr(app, kAXExtrasMenuBarAttribute).map({ $0 as! AXUIElement }),
              let icon = Self.children(bar).first else { throw HarnessError("no menu-bar icon") }
        AXUIElementPerformAction(icon, kAXPressAction as CFString)
        // Menu items exist before the menu opens; wait until the item is really shown.
        var itemAt: CGPoint?
        _ = eventually(timeout: 3) {
            itemAt = find(in: icon) { Self.string($0, kAXTitleAttribute) == title }
                .flatMap(Self.center(of:)).flatMap(Self.onScreen)
            return itemAt != nil
        }
        guard let itemAt else { throw HarnessError("menu item \(title) did not appear") }
        Self.click(at: itemAt)
    }

    /// The point, if it is inside a display (global, top-left origin coordinates).
    static func onScreen(_ p: CGPoint) -> CGPoint? {
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 0, nil, &count) == .success && count > 0 && p.y > 1 ? p : nil
    }

    static func center(of e: AXUIElement) -> CGPoint? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    /// A left click at a point in global (top-left origin) screen coordinates.
    static func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.08)
        }
    }
}
