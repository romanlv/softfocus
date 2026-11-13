import Foundation

public enum TimeText {
    /// "02:48", or "1:02:48" when an hour or longer.
    public static func digital(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Short human countdown for menus: "45 sec", "12 min", "1.5 hr".
    public static func approximate(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s.rounded(.up))) sec" }
        if s < 3600 { return "\(Int((s / 60).rounded(.up))) min" }
        let hours = (s / 360).rounded() / 10
        return hours == hours.rounded() ? "\(Int(hours)) hr" : String(format: "%.1f hr", hours)
    }

    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) sec" }
        if s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return "\(s / 60) min \(s % 60) sec"
    }
}

/// What the rest card shows at a moment in time.
public struct RestCardModel: Equatable, Sendable {
    public var elapsed: String
    public var remaining: String
    public var progress: Double
    public var isComplete: Bool
    public var canSnooze: Bool
    public var canFinish: Bool
    public var headline: String
}

/// What the heads-up panel shows.
public struct HeadsUpModel: Equatable, Sendable {
    public var countdown: String
}

extension Cycle {
    public func restCard(at now: Date) -> RestCardModel? {
        let start: Date, end: Date, done: Bool
        switch phase {
        case .resting(let s, let e): (start, end, done) = (s, e, false)
        case .restDone(let s, let e): (start, end, done) = (s, e, true)
        default: return nil
        }
        let length = end.timeIntervalSince(start)
        let elapsed = max(0, now.timeIntervalSince(start))
        let remaining = done ? 0 : max(0, end.timeIntervalSince(now))
        let progress = done || length <= 0 ? 1 : min(1, elapsed / length)
        return RestCardModel(
            elapsed: TimeText.digital(elapsed),
            remaining: TimeText.digital(remaining.rounded(.up)),
            progress: progress,
            isComplete: done,
            canSnooze: canSnooze,
            canFinish: canFinish,
            headline: done ? "Rest complete" : "Time to rest your eyes"
        )
    }

    public func headsUp(at now: Date) -> HeadsUpModel? {
        guard case .working(let due, true) = phase else { return nil }
        return HeadsUpModel(countdown: TimeText.digital(due.timeIntervalSince(now).rounded(.up)))
    }

    /// The first, informational line of the menu bar menu.
    public func statusLine(at now: Date) -> String {
        switch phase {
        case .off: "Breaks are off"
        case .working(let due, _): "Next rest in \(TimeText.approximate(due.timeIntervalSince(now)))"
        case .resting(_, let end): "Resting, \(TimeText.digital(end.timeIntervalSince(now).rounded(.up))) left"
        case .restDone: "Rest complete"
        case .away: "Paused while you are away"
        }
    }
}

// MARK: Keyboard on the rest card

public enum RestKey: Sendable { case escape, returnKey, space, other }

public enum RestKeyAction: Equatable, Sendable {
    case snooze(TimeInterval)
    case finish
}

public enum RestKeys {
    /// Return/Space are ignored this long after the card appears, so a keystroke
    /// typed just as the rest starts does not dismiss it.
    public static let finishGuard: TimeInterval = 0.5

    public static func action(for key: RestKey, shift: Bool, cardShownFor: TimeInterval, cycle: Cycle) -> RestKeyAction? {
        switch key {
        case .escape:
            return cycle.canSnooze ? .snooze(shift ? 5 * 60 : 60) : nil
        case .returnKey, .space:
            return cycle.canFinish && cardShownFor >= finishGuard ? .finish : nil
        case .other:
            return nil
        }
    }
}

/// Snooze choices offered on the card and in the heads-up panel.
public enum SnoozeChoice {
    public static let seconds: [TimeInterval] = [60, 5 * 60, 15 * 60]
}

// MARK: Slider scales for the Settings window

/// Units a duration can be typed in.
public enum DurationUnit: String, CaseIterable, Sendable {
    case seconds, minutes

    public var factor: TimeInterval { self == .seconds ? 1 : 60 }
    public var shortLabel: String { self == .seconds ? "sec" : "min" }
}

/// Rules for a type-in duration with a stepper, a unit menu and presets.
/// Typing gives any exact value; the stepper moves to the next round value.
public struct DurationField: Sendable, Equatable {
    public let units: [DurationUnit]
    /// Stepper increment, in each unit.
    public let steps: [DurationUnit: Int]
    public let range: ClosedRange<TimeInterval>
    public let presets: [TimeInterval]
    /// Smallest step a typed value is rounded to, in seconds.
    public var granularity: TimeInterval = 1

    public static func work(_ limits: SettingsLimits) -> DurationField {
        DurationField(units: [.minutes], steps: [.minutes: 5], range: limits.work,
                      presets: [1200, 1800, 2700, 3600], granularity: 60) // shown in whole minutes, so stored that way
    }

    public static func rest(_ limits: SettingsLimits) -> DurationField {
        DurationField(units: [.seconds, .minutes], steps: [.seconds: 5, .minutes: 1], range: limits.rest,
                      presets: [20, 60, 120, 300])
    }

    /// The unit a value is shown in: minutes when it is whole minutes, else seconds.
    public func unit(for seconds: TimeInterval) -> DurationUnit {
        guard units.contains(.seconds) else { return units[0] }
        guard units.contains(.minutes) else { return .seconds }
        return seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? .minutes : .seconds
    }

    public func amount(_ seconds: TimeInterval, in unit: DurationUnit) -> Int {
        Int((seconds / unit.factor).rounded())
    }

    /// Seconds for a typed amount, kept inside the allowed range.
    public func seconds(amount: Int, unit: DurationUnit) -> TimeInterval {
        clamp(TimeInterval(amount) * unit.factor)
    }

    /// One stepper click: to the next multiple of the step, up or down, down to the
    /// lower limit. Below one minute, a minutes field carries on in seconds if it can.
    public func stepped(_ seconds: TimeInterval, unit: DurationUnit, up: Bool) -> TimeInterval {
        let step = Double(steps[unit] ?? 1)
        let q = seconds / unit.factor / step
        let nextQ = up ? (q + 1e-9).rounded(.down) + 1 : (q - 1e-9).rounded(.up) - 1
        let next = nextQ * step * unit.factor
        if !up, unit == .minutes, next < 60, units.contains(.seconds) {
            return stepped(seconds, unit: .seconds, up: false)
        }
        return clamp(next)
    }

    /// Changing the unit keeps the duration ("2 min" → "120 sec"). Going to minutes
    /// rounds to whole minutes, since that is all the field can show.
    public func changingUnit(_ seconds: TimeInterval, from old: DurationUnit, to new: DurationUnit) -> TimeInterval {
        guard new == .minutes else { return seconds }
        return clamp(max(60, (seconds / 60).rounded() * 60))
    }

    public func clamp(_ s: TimeInterval) -> TimeInterval { min(max(s, range.lowerBound), range.upperBound) }

    /// "20 min", "45 sec".
    public func label(_ seconds: TimeInterval) -> String {
        let u = unit(for: seconds)
        return "\(amount(seconds, in: u)) \(u.shortLabel)"
    }

    public struct Parsed: Equatable, Sendable {
        /// Nil when the text is not a number (keep the old value).
        public var seconds: TimeInterval?
        /// Tells the user what was changed, if anything.
        public var note: String?
    }

    /// Reads what the user typed in `unit`: accepts decimals ("1.5", "1,5"), rounds to
    /// the field's granularity and keeps it in range, saying so when it had to.
    public func parse(_ text: String, unit: DurationUnit) -> Parsed {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(cleaned), number.isFinite else {
            return Parsed(seconds: nil, note: "Type a number, like 20.")
        }
        let raw = number * unit.factor
        let rounded = (raw / granularity).rounded() * granularity
        let value = clamp(rounded)
        if value != rounded { return Parsed(seconds: value, note: "Choose between \(rangeText).") }
        if rounded != raw { return Parsed(seconds: value, note: "Rounded to \(label(value)).") }
        return Parsed(seconds: value, note: nil)
    }

    /// "5 sec – 60 min".
    public var rangeText: String { "\(label(range.lowerBound)) – \(label(range.upperBound))" }
}

// MARK: External commands (URL scheme and AppleScript share these)

public enum ExternalCommand: Equatable, Sendable {
    case restNow
    case finish
    case snooze(TimeInterval)
    case setEnabled(Bool)
    case toggle
    case restartCountdown
    case openSettings

    public static let urlScheme = "softfocus"

    /// softfocus://rest-now, softfocus://finish, softfocus://snooze?minutes=5,
    /// softfocus://enable, softfocus://disable, softfocus://toggle, softfocus://restart, softfocus://settings
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme else { return nil }
        let verb = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch verb {
        case "rest-now", "rest": self = .restNow
        case "finish": self = .finish
        case "snooze":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let minutes = items.first { $0.name == "minutes" }.flatMap { Double($0.value ?? "") } ?? 1
            guard minutes > 0 else { return nil }
            self = .snooze(minutes * 60)
        case "enable": self = .setEnabled(true)
        case "disable": self = .setEnabled(false)
        case "toggle": self = .toggle
        case "restart": self = .restartCountdown
        case "settings": self = .openSettings
        default: return nil
        }
    }

    /// The cycle event this command maps to, or nil for UI-only commands.
    public func event(given cycle: Cycle) -> Event? {
        switch self {
        case .restNow: .restNow
        case .finish: .finish
        case .snooze(let s): .snooze(s)
        case .setEnabled(let on): .setEnabled(on)
        case .toggle: .setEnabled(!cycle.settings.enabled)
        case .restartCountdown: .restartCountdown
        case .openSettings: nil
        }
    }
}

/// Explains a failed login-item change. macOS registers the app at the path it runs
/// from, so the common failures are about where the app is, not the request itself.
public enum LoginItemProblem {
    public static func message(for error: Error, appPath: String, appExists: Bool) -> String {
        if !appExists {
            return "Softfocus was moved or deleted while it was running. Quit it, then open it again from its new place."
        }
        if appPath.contains("/AppTranslocation/") {
            return "macOS is running Softfocus from a temporary copy. Move it to the Applications folder, then open it again."
        }
        return "Could not change the login item: \(error.localizedDescription)"
    }
}
