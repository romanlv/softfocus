import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import OSLog
import SoftfocusCore
import ServiceManagement

let log = Logger(subsystem: "app.softfocus", category: "app")

/// Launch configuration. Test-only knobs come from the environment so the shipped
/// app behaves normally unless a test harness sets them.
public struct AppConfig: Sendable {
    /// UserDefaults domain. Tests use a throwaway one.
    public var defaultsSuite: String?
    /// Path of the Unix socket for the test-control channel. Nil = channel closed.
    public var controlSocket: String?
    /// Testing mode: short durations allowed, silent chimes, fake login item.
    public var testing: Bool
    public var tickInterval: TimeInterval
    /// Fixed idle reading, so tests do not depend on whether someone is touching the Mac.
    public var idleOverride: TimeInterval?
    /// Testing mode uses a fake login item unless this is set (SOFTFOCUS_REAL_LOGIN_ITEM=1).
    public var realLoginItem = false
    /// How the fake login item answers a register call (SOFTFOCUS_FAKE_LOGIN).
    public var fakeLoginAnswer: String?

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        let testing = env["SOFTFOCUS_TESTING"] == "1"
        return AppConfig(
            defaultsSuite: env["SOFTFOCUS_DEFAULTS_SUITE"],
            controlSocket: env["SOFTFOCUS_CONTROL_SOCKET"],
            testing: testing,
            tickInterval: testing ? 0.1 : 0.5,
            idleOverride: env["SOFTFOCUS_FAKE_IDLE"].flatMap(Double.init),
            realLoginItem: env["SOFTFOCUS_REAL_LOGIN_ITEM"] == "1",
            fakeLoginAnswer: env["SOFTFOCUS_FAKE_LOGIN"]
        )
    }
}

// MARK: Idle time

@MainActor
public protocol IdleSource: AnyObject {
    func idleSeconds() -> TimeInterval
}

/// Seconds since the last keyboard, mouse or trackpad input, with an optional
/// test override.
@MainActor
public final class SystemIdleSource: IdleSource {
    public var override: TimeInterval?
    public init() {}

    public func idleSeconds() -> TimeInterval {
        if let override { return override }
        // Watching a video or presenting: no input, but not resting either. (Not on a
        // locked screen: then nobody is watching, whatever keeps the display on.)
        if Self.displayKeptAwake() && !AppCoordinator.sessionLocked() { return 0 }
        return rawIdleSeconds()
    }

    /// Seconds since the last real keyboard/mouse input, with no adjustments.
    public func rawIdleSeconds() -> TimeInterval {
        if let override { return override }
        // ~0 means "any input event type".
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// True while some app holds a "keep the display awake" power assertion
    /// (video players, slideshows, screen sharing).
    static func displayKeptAwake() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict[kIOPMAssertPreventUserIdleDisplaySleep] ?? 0) > 0
    }
}

// MARK: Presence (sleep, lock, screen saver)

@MainActor
public final class PresenceMonitor {
    private var tracker = PresenceTracker()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let onChange: @MainActor (Bool) -> Void

    public init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification, .systemSleep, true)
        observe(ws, NSWorkspace.didWakeNotification, .systemSleep, false)
        observe(ws, NSWorkspace.screensDidSleepNotification, .displaySleep, true)
        observe(ws, NSWorkspace.screensDidWakeNotification, .displaySleep, false)
        observe(ws, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true)
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)
        let dist = DistributedNotificationCenter.default()
        observe(dist, Notification.Name("com.apple.screenIsLocked"), .locked, true)
        observe(dist, Notification.Name("com.apple.screenIsUnlocked"), .locked, false)
        observe(dist, Notification.Name("com.apple.screensaver.didstart"), .screenSaver, true)
        observe(dist, Notification.Name("com.apple.screensaver.didstop"), .screenSaver, false)
    }

    public func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ reason: PresenceTracker.Reason, _ on: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signal(reason, on) }
        }
        tokens.append((center, token))
    }

    func signal(_ reason: PresenceTracker.Reason, _ on: Bool) {
        if let away = tracker.set(reason, on) { onChange(away) }
    }

    /// Forgets every away reason (used when a "back" notification was evidently missed).
    func reset() {
        if tracker.clear() { onChange(false) }
    }
}

// MARK: Strict-mode focus lock

@MainActor
public protocol FocusLocking: AnyObject {
    func lock()
    func unlock()
}

@MainActor
public final class PresentationFocusLock: FocusLocking {
    private var saved: NSApplication.PresentationOptions?
    public init() {}

    public static let lockedOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableHideApplication,
    ]

    public func lock() {
        if saved == nil { saved = NSApp.presentationOptions }
        NSApp.presentationOptions = Self.lockedOptions
    }

    public func unlock() {
        NSApp.presentationOptions = saved ?? []
        saved = nil
    }
}

// MARK: Sounds

@MainActor
public protocol ChimePlaying: AnyObject {
    func play(_ chime: Chime)
    func startLoop()
    func stopLoop()
}

/// Uses sounds that ship with macOS. The end-of-rest reminder repeats every few
/// seconds until the user presses Finish.
@MainActor
public final class SystemChimePlayer: ChimePlaying {
    private var loopTimer: Timer?
    /// The reminder stops by itself after this many plays (about half a minute),
    /// so an empty room is not chimed at forever.
    static let maxLoopPlays = 8
    public init() {}

    static func soundName(for chime: Chime) -> String { chime == .restStart ? "Glass" : "Hero" }

    func sound(for chime: Chime) -> NSSound? { NSSound(named: Self.soundName(for: chime)) }

    public func play(_ chime: Chime) {
        sound(for: chime)?.play()
    }

    public func startLoop() {
        stopLoop()
        play(.restEnd)
        var plays = 1
        loopTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                plays += 1
                self?.play(.restEnd)
                if plays >= Self.maxLoopPlays { self?.stopLoop() }
            }
        }
    }

    public func stopLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
    }
}

/// Silent player for tests.
@MainActor
public final class SilentChimePlayer: ChimePlaying {
    public private(set) var looping = false
    public init() {}
    public func play(_ chime: Chime) {}
    public func startLoop() { looping = true }
    public func stopLoop() { looping = false }
}

// MARK: Hooks

@MainActor
public final class HookRunner {
    public init() {}

    /// Interpreter from a script's first line ("#!/bin/zsh -f", "#!/usr/bin/env python3"),
    /// falling back to /bin/sh.
    static func interpreter(for url: URL) -> (URL, [String]) {
        let fallback = (URL(fileURLWithPath: "/bin/sh"), [String]())
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 512) else { return fallback }
        let text = String(decoding: head, as: UTF8.self) // lossy: a split character later on is fine
        guard text.hasPrefix("#!") else { return fallback }
        let line = text.dropFirst(2).prefix { $0 != "\n" && $0 != "\r" }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, FileManager.default.isExecutableFile(atPath: first) else { return fallback }
        return (URL(fileURLWithPath: first), Array(parts.dropFirst()))
    }

    public static let appleScriptExtensions: Set<String> = ["scpt", "scptd", "applescript"]
    public static let automatorExtensions: Set<String> = ["workflow"]

    /// Runs the file at `path`. Shell scripts and binaries get the hook name as
    /// their first argument and in SOFTFOCUS_HOOK. Returns false if it could not start.
    @discardableResult
    public func run(path: String, hook: Hook) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        do {
            if Self.appleScriptExtensions.contains(ext) {
                try NSUserAppleScriptTask(url: url).execute(withAppleEvent: nil) { _, error in
                    if let error { log.error("hook \(path) failed: \(error.localizedDescription)") }
                }
            } else if Self.automatorExtensions.contains(ext) {
                try NSUserAutomatorTask(url: url).execute(withInput: nil) { _, error in
                    if let error { log.error("hook \(path) failed: \(error.localizedDescription)") }
                }
            } else {
                let process = Process()
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    process.executableURL = url
                    process.arguments = [hook.rawValue]
                } else {
                    // A script without the executable bit: run it with the interpreter
                    // its #! line names, or the shell.
                    let (interpreter, args) = Self.interpreter(for: url)
                    process.executableURL = interpreter
                    process.arguments = args + [url.path, hook.rawValue]
                }
                var env = ProcessInfo.processInfo.environment
                env["SOFTFOCUS_HOOK"] = hook.rawValue
                process.environment = env
                try process.run()
            }
            return true
        } catch {
            log.error("hook \(path) could not start: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: Launch at login

@MainActor
public protocol LoginItemControlling: AnyObject {
    /// Read fresh every time: the user can change it in System Settings at any moment.
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings › General › Login Items.
    func openSystemSettings()
}

/// The app itself as a login item (SMAppService, macOS 13+). No helper bundle needed.
@MainActor
public final class SystemLoginItem: LoginItemControlling {
    public init() {}

    public var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled // .notRegistered, .notFound
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }

    public func unregister() throws {
        guard state != .disabled else { return }
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// In-memory login item for tests. `registerResult` decides what macOS "answers"
/// when the app registers (set SOFTFOCUS_FAKE_LOGIN=requiresApproval to simulate a Mac
/// that wants the user's OK first, or =fail for an error).
@MainActor
public final class FakeLoginItem: LoginItemControlling {
    public enum Answer: String { case enabled, requiresApproval, fail }
    public var state: LoginItemState = .disabled
    public var registerAnswer: Answer
    public private(set) var settingsOpened = 0

    public init(registerAnswer: Answer = .enabled) { self.registerAnswer = registerAnswer }

    public func register() throws {
        switch registerAnswer {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .fail: throw NSError(domain: "FakeLoginItem", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed."])
        }
    }

    public func unregister() throws { state = .disabled }
    public func openSystemSettings() { settingsOpened += 1 }
}
