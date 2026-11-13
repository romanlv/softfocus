import Foundation

/// User preferences. Durations are seconds.
public struct Settings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    /// Time at the screen between rests.
    public var workSeconds: TimeInterval = 20 * 60
    /// Length of one rest.
    public var restSeconds: TimeInterval = 2 * 60
    /// How early the heads-up panel appears before a rest. 0 disables it.
    public var headsUpSeconds: TimeInterval = 10
    /// Strict: no snoozing or finishing early; Dock, menu bar and app switching are locked.
    public var strictMode: Bool = false
    /// Close the rest card automatically when the rest is over.
    public var autoFinish: Bool = false
    /// Treat long idle time as a rest and restart the countdown.
    public var smartReset: Bool = true
    public var soundsOn: Bool = true
    public var showInDock: Bool = false
    public var showInMenuBar: Bool = true
    public var launchAtLogin: Bool = false
    /// Script, AppleScript or Automator workflow run when a rest starts.
    public var startHookPath: String?
    /// Same, run when a rest ends.
    public var endHookPath: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key is optional so older saved settings keep loading as fields are added.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        workSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .workSeconds) ?? d.workSeconds
        restSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .restSeconds) ?? d.restSeconds
        headsUpSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .headsUpSeconds) ?? d.headsUpSeconds
        strictMode = try c.decodeIfPresent(Bool.self, forKey: .strictMode) ?? d.strictMode
        autoFinish = try c.decodeIfPresent(Bool.self, forKey: .autoFinish) ?? d.autoFinish
        smartReset = try c.decodeIfPresent(Bool.self, forKey: .smartReset) ?? d.smartReset
        soundsOn = try c.decodeIfPresent(Bool.self, forKey: .soundsOn) ?? d.soundsOn
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? d.showInMenuBar
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        startHookPath = try c.decodeIfPresent(String.self, forKey: .startHookPath)
        endHookPath = try c.decodeIfPresent(String.self, forKey: .endHookPath)
    }

    /// True when the app has no visible way to reach it (no Dock icon, no menu bar item).
    public var isHeadless: Bool { !showInDock && !showInMenuBar }
}

/// Allowed ranges. Tests use `.testing` so a full cycle takes seconds, not minutes.
public struct SettingsLimits: Sendable, Equatable {
    public var work: ClosedRange<TimeInterval>
    public var rest: ClosedRange<TimeInterval>
    public var headsUp: ClosedRange<TimeInterval>

    public init(work: ClosedRange<TimeInterval>, rest: ClosedRange<TimeInterval>, headsUp: ClosedRange<TimeInterval>) {
        self.work = work
        self.rest = rest
        self.headsUp = headsUp
    }

    public static let standard = SettingsLimits(work: 60...(4 * 3600), rest: 5...3600, headsUp: 0...60)
    public static let testing = SettingsLimits(work: 1...(4 * 3600), rest: 1...3600, headsUp: 0...60)
}

extension Settings {
    public func clamped(to limits: SettingsLimits) -> Settings {
        var s = self
        s.workSeconds = workSeconds.clamped(to: limits.work)
        s.restSeconds = restSeconds.clamped(to: limits.rest)
        s.headsUpSeconds = headsUpSeconds.clamped(to: limits.headsUp)
        if s.startHookPath?.isEmpty == true { s.startHookPath = nil }
        if s.endHookPath?.isEmpty == true { s.endHookPath = nil }
        return s
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Persists settings as one JSON value in a UserDefaults domain.
public final class SettingsStore: @unchecked Sendable {
    public static let settingsKey = "softfocus.settings.v1"
    public static let launchedKey = "softfocus.hasLaunched"

    private let defaults: UserDefaults
    public let limits: SettingsLimits

    public init(defaults: UserDefaults, limits: SettingsLimits = .standard) {
        self.defaults = defaults
        self.limits = limits
    }

    public func load() -> Settings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s.clamped(to: limits)
    }

    @discardableResult
    public func save(_ settings: Settings) -> Settings {
        let s = settings.clamped(to: limits)
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        return s
    }

    /// Returns true exactly once per defaults domain.
    public func consumeFirstLaunch() -> Bool {
        if defaults.bool(forKey: Self.launchedKey) { return false }
        defaults.set(true, forKey: Self.launchedKey)
        return true
    }
}
