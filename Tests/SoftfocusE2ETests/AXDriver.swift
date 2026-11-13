import ApplicationServices
import Foundation

/// Drives another app's windows through the macOS accessibility API, the same way
/// VoiceOver or a user's clicks reach SwiftUI controls. Needs the test runner (your
/// terminal) to be allowed under System Settings › Privacy & Security › Accessibility.
struct AXDriver {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    let app: AXUIElement

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
    }

    // MARK: Attributes

    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    // MARK: Finding

    func window(_ identifier: String) -> AXUIElement? {
        let windows = (Self.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.first { Self.string($0, kAXIdentifierAttribute) == identifier }
    }

    /// Breadth-first search below `root` for the first element matching `match`.
    func find(in root: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < 5000 {
            let e = queue.removeFirst()
            seen += 1
            if match(e) { return e }
            queue += Self.children(e)
        }
        return nil
    }

    func element(_ identifier: String, in window: String = "settings") -> AXUIElement? {
        guard let w = self.window(window) else { return nil }
        return find(in: w) { Self.string($0, kAXIdentifierAttribute) == identifier }
    }

    /// Waits for an element to appear (SwiftUI builds its tree lazily).
    func waitFor(_ identifier: String, in window: String = "settings", timeout: TimeInterval = 5) throws -> AXUIElement {
        let deadline = Date() + timeout
        repeat {
            if let e = element(identifier, in: window) { return e }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw HarnessError("no accessibility element '\(identifier)' in window '\(window)'")
    }

    func exists(_ identifier: String) -> Bool { element(identifier) != nil }

    // MARK: Acting

    func press(_ identifier: String) throws {
        let e = try waitFor(identifier)
        let err = AXUIElementPerformAction(e, kAXPressAction as CFString)
        guard err == .success else { throw HarnessError("press \(identifier) failed: \(err.rawValue)") }
    }

    func perform(_ identifier: String, _ action: String) throws {
        let e = try waitFor(identifier)
        let err = AXUIElementPerformAction(e, action as CFString)
        guard err == .success else { throw HarnessError("\(action) on \(identifier) failed: \(err.rawValue)") }
    }

    /// Types into a text field and commits it, like pressing Return.
    func type(_ identifier: String, _ text: String) throws {
        let e = try waitFor(identifier)
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString)
        guard err == .success else { throw HarnessError("typing into \(identifier) failed: \(err.rawValue)") }
        AXUIElementPerformAction(e, kAXConfirmAction as CFString)
    }

    func text(_ identifier: String) -> String? { value(identifier) as? String }

    /// Types into a field without committing (no Return, focus stays).
    func typeWithoutCommit(_ identifier: String, _ text: String) throws {
        let e = try waitFor(identifier)
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString)
        guard err == .success else { throw HarnessError("typing into \(identifier) failed: \(err.rawValue)") }
    }

    /// Opens a pop-up button and picks the item with `title`. Retries the press, since a
    /// press that lands while a previous menu is still closing just closes it.
    func choose(_ title: String, in popUp: String) throws {
        let isItem = { (x: AXUIElement) in
            Self.string(x, kAXRoleAttribute) == kAXMenuItemRole && Self.string(x, kAXTitleAttribute) == title
        }
        for _ in 0..<4 {
            let e = try waitFor(popUp)
            AXUIElementPerformAction(e, kAXPressAction as CFString)
            let deadline = Date() + 1
            while Date() < deadline {
                if let item = find(in: e, isItem) {
                    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    guard err == .success else { throw HarnessError("choosing \(title) failed: \(err.rawValue)") }
                    Thread.sleep(forTimeInterval: 0.3) // let the menu finish closing
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw HarnessError("no menu item '\(title)' in \(popUp)")
    }

    var windows: [AXUIElement] { (Self.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    /// A window (or sheet) containing a button titled `button`, other than `excluding`.
    func dialog(withButton button: String, timeout: TimeInterval = 5) -> (window: AXUIElement, button: AXUIElement)? {
        let deadline = Date() + timeout
        repeat {
            for w in windows {
                if let b = find(in: w, { Self.string($0, kAXRoleAttribute) == kAXButtonRole && Self.string($0, kAXTitleAttribute) == button }) {
                    return (w, b)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    /// Selects a tab of the window's tab view by its title.
    func selectTab(_ title: String, in window: String = "settings") throws {
        guard let w = self.window(window),
              let tab = find(in: w, {
                  [kAXRadioButtonRole, kAXButtonRole].contains(Self.string($0, kAXRoleAttribute) ?? "")
                      && Self.string($0, kAXIdentifierAttribute)?.hasPrefix("settings.") != true
                      && (Self.string($0, kAXTitleAttribute) == title || Self.string($0, kAXDescriptionAttribute) == title)
              })
        else { throw HarnessError("no tab '\(title)'") }
        let err = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        guard err == .success else { throw HarnessError("select tab \(title) failed: \(err.rawValue)") }
    }

    func value(_ identifier: String) -> AnyObject? {
        element(identifier).flatMap { Self.attr($0, kAXValueAttribute) }
    }

    /// 0/1 for a toggle.
    func isOn(_ identifier: String) -> Bool? { (value(identifier) as? NSNumber)?.boolValue }

    func setValue(_ identifier: String, _ number: Double) throws {
        let e = try waitFor(identifier)
        let err = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, number as CFNumber)
        guard err == .success else { throw HarnessError("set \(identifier) failed: \(err.rawValue)") }
    }

    /// Every identifier currently in the window, for diagnostics.
    func identifiers(in window: String = "settings") -> [String] {
        guard let w = self.window(window) else { return [] }
        var out: [String] = []
        var queue = [w]
        while !queue.isEmpty {
            let e = queue.removeFirst()
            if let id = Self.string(e, kAXIdentifierAttribute), !id.isEmpty { out.append(id) }
            queue += Self.children(e)
        }
        return out
    }
}
