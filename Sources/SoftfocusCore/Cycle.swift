import Foundation

/// Where we are in the work/rest loop.
public enum Phase: Equatable, Sendable {
    /// Breaks are switched off.
    case off
    /// Counting down to the next rest.
    case working(due: Date, headsUpShown: Bool)
    /// Rest card is up and the rest is running.
    case resting(start: Date, end: Date)
    /// Rest time is over; waiting for the user to press Finish.
    case restDone(start: Date, end: Date)
    /// Nobody at the Mac: asleep, locked or screen saver (`byIdle == false`), or no
    /// input for long enough (`byIdle == true`). The next work period starts on return.
    case away(byIdle: Bool)

    public var name: String {
        switch self {
        case .off: "off"
        case .working: "working"
        case .resting: "resting"
        case .restDone: "restDone"
        case .away(let idle): idle ? "idle" : "away"
        }
    }
}

public enum Chime: String, Sendable, Codable { case restStart, restEnd }
public enum Hook: String, Sendable, Codable { case start, end }

/// Side effects the app shell must perform. The cycle never touches the system itself.
public enum Effect: Equatable, Sendable {
    case showHeadsUp
    case hideHeadsUp
    case showRest
    case hideRest
    case lockFocus
    case unlockFocus
    case playChime(Chime)
    case startChimeLoop
    case stopChime
    case runHook(Hook)
}

/// Everything that can happen to the cycle.
public enum Event: Equatable, Sendable {
    /// Time passed. The shell sends this on a timer.
    case tick
    case setEnabled(Bool)
    /// Start a rest immediately.
    case restNow
    /// During a rest: close it and come back in N seconds.
    /// While working: push the next rest back by N seconds.
    case snooze(TimeInterval)
    /// Close a rest and start a fresh work period.
    case finish
    /// Restart the work countdown from the full interval.
    case restartCountdown
    /// Seconds since the last keyboard/mouse input.
    case idleSample(TimeInterval)
    /// Sleep/lock/screen saver started (true) or ended (false).
    case presence(away: Bool)
    case settingsChanged(Settings)
}

/// The rest-cycle state machine. A value type: feed it events with a timestamp,
/// it returns the effects to perform. Deterministic, so tests drive it with fake dates.
public struct Cycle: Equatable, Sendable {
    public private(set) var phase: Phase
    public private(set) var settings: Settings
    public private(set) var focusLocked = false
    public private(set) var chimeLooping = false
    /// Latest seconds-since-input reading (the shell samples it on every tick).
    public private(set) var idle: TimeInterval = 0
    /// Asleep, locked or screen saver right now (even while a rest keeps running).
    public private(set) var presenceAway = false

    public init(settings: Settings, now: Date) {
        self.settings = settings
        self.phase = settings.enabled ? .working(due: now + settings.workSeconds, headsUpShown: false) : .off
    }

    // MARK: Derived rules

    public var isRestVisible: Bool {
        switch phase {
        case .resting, .restDone: true
        default: false
        }
    }

    // A strict rest stays strict until it is over, whatever the settings say meanwhile
    // (focusLocked is the rest's own strictness; settings changes apply to the next one).
    public var canSnooze: Bool {
        switch phase {
        case .working: true
        case .resting, .restDone: !focusLocked && !settings.strictMode
        case .off, .away: false
        }
    }

    public var canFinish: Bool {
        switch phase {
        case .resting: !focusLocked && !settings.strictMode
        case .restDone: true
        default: false
        }
    }

    public var canRestNow: Bool {
        switch phase {
        case .working, .off, .away(byIdle: true): true // idle: they are clicking, so they are back
        default: false
        }
    }

    /// Strict mode blocks quitting while a rest is locked.
    public var canQuit: Bool { !focusLocked }

    public func secondsUntilRest(at now: Date) -> TimeInterval? {
        if case .working(let due, _) = phase { return max(0, due.timeIntervalSince(now)) }
        return nil
    }

    /// Fraction of the work period already used, 0...1 (for the menu bar icon).
    public func workProgress(at now: Date) -> Double? {
        guard let left = secondsUntilRest(at: now), settings.workSeconds > 0 else { return nil }
        return (1 - left / settings.workSeconds).clamped(to: 0...1)
    }

    // MARK: Events

    public mutating func handle(_ event: Event, at now: Date) -> [Effect] {
        var fx: [Effect] = []
        switch event {
        case .tick:
            advance(now, &fx)

        case .setEnabled(let on):
            settings.enabled = on
            // A strict rest can't be escaped by switching breaks off (URL, script):
            // the change is kept and takes effect when the rest is finished.
            if !focusLocked { applyEnabled(now, &fx) }

        case .restNow:
            if canRestNow { beginRest(now, rested: 0, &fx) }

        case .snooze(let seconds):
            guard canSnooze, seconds > 0 else { break }
            switch phase {
            case .working(let due, let shown):
                if shown { fx.append(.hideHeadsUp) }
                phase = .working(due: max(due, now) + seconds, headsUpShown: false)
            case .resting, .restDone:
                closeRest(&fx)
                phase = .working(due: now + seconds, headsUpShown: false)
            default: break
            }

        case .finish:
            guard canFinish else { break }
            closeRest(&fx)
            phase = settings.enabled ? freshWork(now) : .off

        case .restartCountdown:
            if case .working(_, let shown) = phase {
                if shown { fx.append(.hideHeadsUp) }
                phase = freshWork(now)
            }

        case .idleSample(let seconds):
            idle = max(0, seconds)
            if case .away(byIdle: true) = phase, idle < SmartReset.activeIdle, !presenceAway {
                // First input after being idle: a full work period from now.
                phase = settings.enabled ? freshWork(now) : .off
                break
            }
            guard settings.smartReset else { break }
            let gone = idle >= SmartReset.idleThreshold(work: settings.workSeconds, rest: settings.restSeconds)
            switch phase {
            case .working(_, let shown) where gone:
                // Long enough away to count as a rest: pause until they come back.
                if shown { fx.append(.hideHeadsUp) }
                phase = .away(byIdle: true)
            case .restDone where gone:
                // The rest ended and they never came back: close the card quietly.
                closeRest(&fx)
                phase = .away(byIdle: true)
            default:
                break
            }

        case .presence(let away):
            presenceAway = away
            if away {
                switch phase {
                case .working(_, let shown) where settings.smartReset:
                    // Asleep, locked or screen saver: pause; a fresh period starts on return.
                    if shown { fx.append(.hideHeadsUp) }
                    phase = .away(byIdle: false)
                case .away(byIdle: true):
                    phase = .away(byIdle: false) // now wait for the unlock, not for input
                case .restDone where settings.smartReset:
                    // Rest over and they locked up and left: close the card quietly.
                    closeRest(&fx)
                    phase = .away(byIdle: false)
                default:
                    // Off, already away, or resting: a locked screen during a rest *is*
                    // resting, so the rest (strict or not) carries on.
                    break
                }
            } else if case .away = phase {
                phase = settings.enabled ? freshWork(now) : .off
            }

        case .settingsChanged(let new):
            let old = settings
            settings = new
            // A strict rest is a promise: switching breaks off, strict off or a shorter
            // rest is saved but can't end the rest in progress; it applies afterwards.
            if old.enabled != new.enabled {
                if !focusLocked { applyEnabled(now, &fx) }
            } else if case .working(_, let shown) = phase, old.workSeconds != new.workSeconds {
                if shown { fx.append(.hideHeadsUp) }
                phase = freshWork(now)
            }
            if isRestVisible {
                if new.strictMode && !focusLocked && !isRestDone { fx.append(.lockFocus); focusLocked = true }
            }
            if !new.soundsOn && chimeLooping { fx.append(.stopChime); chimeLooping = false }
            // A new rest length applies to the rest in progress.
            if case .resting(let start, let end) = phase, old.restSeconds != new.restSeconds {
                let newEnd = start + new.restSeconds
                if !focusLocked || newEnd > end { phase = .resting(start: start, end: newEnd) }
            }
            // Auto-finish switched on while the card waits for Finish: finish now.
            if new.autoFinish && !old.autoFinish, isRestDone {
                closeRest(&fx)
                phase = new.enabled ? freshWork(now) : .off
            }
            // Idle pausing switched off while paused for idleness: carry on now.
            if !new.smartReset, case .away(byIdle: true) = phase { phase = new.enabled ? freshWork(now) : .off }
            advance(now, &fx)
        }
        return fx
    }

    // MARK: Internals

    private var restEnd: Date? {
        if case .resting(_, let end) = phase { return end }
        return nil
    }

    private var isRestDone: Bool {
        if case .restDone = phase { return true }
        return false
    }

    private func freshWork(_ now: Date) -> Phase {
        .working(due: now + settings.workSeconds, headsUpShown: false)
    }

    private mutating func applyEnabled(_ now: Date, _ fx: inout [Effect]) {
        if settings.enabled {
            if case .off = phase { phase = freshWork(now) }
        } else {
            switch phase {
            case .working(_, true): fx.append(.hideHeadsUp)
            case .resting, .restDone: closeRest(&fx)
            default: break
            }
            phase = .off
        }
    }

    private mutating func advance(_ now: Date, _ fx: inout [Effect]) {
        switch phase {
        case .working(let due, let shown):
            if now >= due {
                if settings.smartReset, idle >= max(settings.restSeconds, SmartReset.minimumAway) {
                    // Already away for a whole rest: no card for an empty desk.
                    if shown { fx.append(.hideHeadsUp) }
                    phase = .away(byIdle: true)
                } else {
                    // Time already spent away from the keyboard counts towards this rest.
                    // Never so much that the card would only flash: keep at least 10 s.
                    let credit = settings.smartReset && idle >= SmartReset.creditIdle
                        ? min(idle, max(0, settings.restSeconds - SmartReset.minimumCard)) : 0
                    beginRest(now, rested: credit, &fx)
                }
            } else if !shown, settings.headsUpSeconds > 0,
                      settings.workSeconds > settings.headsUpSeconds,
                      due.timeIntervalSince(now) <= settings.headsUpSeconds {
                fx.append(.showHeadsUp)
                phase = .working(due: due, headsUpShown: true)
            }
        case .resting where now >= restEnd! && presenceAway && settings.smartReset:
            // The rest ran out while the Mac was locked or asleep: no chime for an empty
            // room; the next work period starts when they are back.
            closeRest(&fx)
            phase = .away(byIdle: false)
        case .resting(let start, let end) where now >= end:
            if settings.autoFinish {
                if settings.soundsOn { fx.append(.playChime(.restEnd)) }
                closeRest(&fx)
                phase = settings.enabled ? freshWork(now) : .off
            } else {
                phase = .restDone(start: start, end: end)
                if settings.soundsOn { fx.append(.startChimeLoop); chimeLooping = true }
            }
        default:
            break
        }
    }

    private mutating func beginRest(_ now: Date, rested: TimeInterval, _ fx: inout [Effect]) {
        if case .working(_, true) = phase { fx.append(.hideHeadsUp) }
        let start = now - min(rested, settings.restSeconds)
        phase = .resting(start: start, end: start + settings.restSeconds)
        fx.append(.runHook(.start))
        fx.append(.showRest)
        if settings.soundsOn { fx.append(.playChime(.restStart)) }
        if settings.strictMode { fx.append(.lockFocus); focusLocked = true }
    }

    private mutating func closeRest(_ fx: inout [Effect]) {
        fx.append(.hideRest)
        if chimeLooping { fx.append(.stopChime); chimeLooping = false }
        if focusLocked { fx.append(.unlockFocus); focusLocked = false }
        fx.append(.runHook(.end))
    }
}

public enum SmartReset {
    /// Idle seconds that count as having taken a rest. Grows with the work interval:
    /// rest length plus about a minute per 15 minutes of work, flattened by a 0.7 power.
    public static func idleThreshold(work: TimeInterval, rest: TimeInterval) -> TimeInterval {
        rest + 60 * pow(max(work, 0) / 900, 0.7)
    }

    /// Idle below this means someone is using the Mac again.
    public static let activeIdle: TimeInterval = 2

    /// Idle at least this long when a rest is due counts towards the rest.
    /// (Shorter pauses are just reading or thinking.)
    public static let creditIdle: TimeInterval = 15

    /// Idle at least this long (and at least a rest's worth) when a rest is due means
    /// nobody is there: no card. Someone reading can easily sit still for 20 s.
    public static let minimumAway: TimeInterval = 60

    /// A credited rest still shows the card for at least this long.
    public static let minimumCard: TimeInterval = 10
}
