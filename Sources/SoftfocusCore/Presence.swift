import Foundation

/// Combines the independent "user is away" signals (sleep, display sleep, lock,
/// screen saver, fast user switching) into one away/back state.
public struct PresenceTracker: Sendable, Equatable {
    public enum Reason: String, Hashable, Sendable, CaseIterable {
        case systemSleep, displaySleep, locked, screenSaver, sessionInactive
    }

    public private(set) var active: Set<Reason> = []

    public init() {}

    public var isAway: Bool { !active.isEmpty }

    /// Records a signal. Returns the new away value if it changed, otherwise nil.
    public mutating func set(_ reason: Reason, _ on: Bool) -> Bool? {
        let was = isAway
        if on { active.insert(reason) } else { active.remove(reason) }
        // Waking the machine also wakes the displays.
        if reason == .systemSleep && !on { active.remove(.displaySleep) }
        return was == isAway ? nil : isAway
    }

    /// Drops every reason. Returns true if that ended an away state.
    public mutating func clear() -> Bool {
        let was = isAway
        active.removeAll()
        return was
    }
}
