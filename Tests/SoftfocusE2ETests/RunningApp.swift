import CoreGraphics
import AppKit
import Foundation
import SoftfocusCore

/// Launches the built Softfocus.app in testing mode with a throwaway defaults domain
/// and talks to it over the control socket.
final class RunningApp {
    static var bundleURL: URL? {
        ProcessInfo.processInfo.environment["SOFTFOCUS_APP"].map { URL(fileURLWithPath: $0) }
    }

    static var isAvailable: Bool {
        guard let url = bundleURL else { return false }
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/Softfocus").path)
    }

    /// Where tests leave screenshots and other artifacts for humans to look at.
    static var artifactsDir: URL {
        let dir = (bundleURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("e2e-artifacts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let suite: String
    let socketPath: String
    let workDir: URL
    let extraEnv: [String: String]
    private(set) var process: Process
    private(set) var client: ControlClient

    var pid: pid_t { process.processIdentifier }

    /// - Parameters:
    ///   - settings: written to the defaults domain before launch.
    ///   - firstLaunch: when false the "first launch" flag is pre-set, so Settings does not open.
    ///   - suite: reuse an existing domain (to test persistence across relaunches).
    ///   - env: extra environment for the app (e.g. SOFTFOCUS_FAKE_LOGIN).
    init(settings: Settings? = nil, firstLaunch: Bool = false, suite: String? = nil, env: [String: String] = [:]) throws {
        extraEnv = env
        let id = UUID().uuidString.prefix(8).lowercased()
        socketPath = NSTemporaryDirectory() + "re2e-\(id).sock"
        workDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("softfocus-e2e-\(id)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // An absolute path as the suite name keeps the app's preferences in our temp
        // folder instead of ~/Library/Preferences, so nothing is left behind.
        self.suite = suite ?? workDir.appendingPathComponent("defaults").path

        let defaults = UserDefaults(suiteName: self.suite)!
        if let settings { defaults.set(try JSONEncoder().encode(settings), forKey: SettingsStore.settingsKey) }
        if !firstLaunch { defaults.set(true, forKey: SettingsStore.launchedKey) }
        defaults.synchronize()

        (process, client) = try Self.launch(suite: self.suite, socket: socketPath, extra: env)
    }

    private static func launch(suite: String, socket: String, extra: [String: String]) throws -> (Process, ControlClient) {
        guard let bundle = bundleURL else { throw HarnessError("SOFTFOCUS_APP not set") }
        let p = Process()
        p.executableURL = bundle.appendingPathComponent("Contents/MacOS/Softfocus")
        var env = ProcessInfo.processInfo.environment
        env["SOFTFOCUS_TESTING"] = "1"
        env["SOFTFOCUS_DEFAULTS_SUITE"] = suite
        env["SOFTFOCUS_CONTROL_SOCKET"] = socket
        env["SOFTFOCUS_FAKE_IDLE"] = "0"
        env.merge(extra) { $1 }
        p.environment = env
        try p.run()
        let deadline = Date() + 15
        while Date() < deadline {
            if let c = try? ControlClient(path: socket) { return (p, c) }
            if !p.isRunning { throw HarnessError("app exited during launch (status \(p.terminationStatus))") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.terminate()
        throw HarnessError("control socket never came up")
    }

    /// Quits and starts the app again on the same defaults domain.
    func relaunch() throws {
        stopProcess()
        (process, client) = try Self.launch(suite: suite, socket: socketPath, extra: extraEnv)
    }

    @discardableResult
    func send(_ request: ControlRequest) throws -> ControlResponse {
        try client.send(request)
    }

    func state() throws -> StateSnapshot {
        try send(.init(.state)).state!
    }

    func ui() throws -> UISnapshot {
        try send(.init(.ui)).ui!
    }

    @discardableResult
    func press(_ target: ControlTarget) throws -> ControlResponse {
        try send(.init(.press, target: target.rawValue))
    }

    func key(_ name: String, shift: Bool = false) throws -> ControlResponse {
        try send(.init(.key, key: name, shift: shift))
    }

    func apply(_ change: (inout Settings) -> Void) throws {
        var s = try state().settings
        change(&s)
        let r = try send(.init(.settings, settings: s))
        guard r.ok else { throw HarnessError(r.error ?? "settings rejected") }
    }

    /// Polls the full UI snapshot until `condition` holds.
    @discardableResult
    func waitFor(_ what: String, timeout: TimeInterval = 10,
                 _ condition: (StateSnapshot, UISnapshot) -> Bool) throws -> (StateSnapshot, UISnapshot) {
        let deadline = Date() + timeout
        var last: ControlResponse?
        while Date() < deadline {
            let r = try send(.init(.ui))
            last = r
            if condition(r.state!, r.ui!) { return (r.state!, r.ui!) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HarnessError("timed out waiting for \(what); last phase \(last?.state?.phase ?? "?")")
    }

    /// Windows this process has on screen, as the window server reports them
    /// (independent of what the app says about itself).
    func onScreenWindows() -> [(layer: Int, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return (layer, rect)
        }
    }

    /// A shell script that appends its argument to a log file, for hook tests.
    func makeHookScript(name: String) throws -> (script: URL, log: URL) {
        let script = workDir.appendingPathComponent("\(name).sh")
        let log = workDir.appendingPathComponent("\(name).log")
        try "#!/bin/sh\necho \"$1 $SOFTFOCUS_HOOK\" >> '\(log.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    private func stopProcess() {
        if process.isRunning {
            process.terminate()
            let deadline = Date() + 5
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func stop() {
        stopProcess()
        try? FileManager.default.removeItem(at: workDir)
    }

    deinit { stopProcess() }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Fast settings for tests: short work period, short rest, silent.
func quickSettings(work: TimeInterval = 60, rest: TimeInterval = 30, _ change: (inout Settings) -> Void = { _ in }) -> Settings {
    var s = Settings()
    s.workSeconds = work
    s.restSeconds = rest
    s.headsUpSeconds = 0
    change(&s)
    return s
}

func approx(_ value: Double?, _ expected: Double, tolerance: Double = 1.5) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date() + timeout
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

/// Whether someone could see and use the screen right now. Focus and accessibility
/// checks need an unlocked session with the display awake.
enum ScreenState {
    static var isLocked: Bool {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (info?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static var isUsable: Bool { !isLocked && CGDisplayIsAsleep(CGMainDisplayID()) == 0 }

    /// Another Softfocus (yours, not the test's) is showing a rest: its overlay covers the
    /// screen and holds the focus, so window tests would only measure that.
    static var otherRestOnScreen: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "Softfocus"
                && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.screenSaverWindow)) - 2
        }
    }

    /// For tests that drive windows through the accessibility API.
    static var canDriveUI: Bool { isUsable && AXDriver.isTrusted && !otherRestOnScreen }
}
