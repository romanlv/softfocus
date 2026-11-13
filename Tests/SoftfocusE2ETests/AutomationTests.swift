import Foundation
import SoftfocusCore
import Testing

/// The AppleScript dictionary, exercised inside the real app with raw event codes
/// (so no terminology lookup and no Automation permission prompt are involved).
extension EndToEndTests {
    func script(_ app: RunningApp, _ source: String) throws -> ControlResponse {
        try app.send(.init(.appleScript, path: source))
    }

    @Test func appleScriptCommandsAndProperties() throws {
        let app = try RunningApp(settings: quickSettings(work: 600, rest: 30))
        defer { app.stop() }
        let me = "tell application id \"app.softfocus.Softfocus\" to"

        // Properties: rest phase, seconds until rest, breaks enabled (read and write).
        var r = try script(app, "\(me) get «property SfPh»")
        #expect(r.ok, "\(r.error ?? "")")
        #expect(r.result == "working")
        r = try script(app, "\(me) get «property SfSc»")
        #expect(approx(r.result.flatMap(Double.init), 600, tolerance: 3), "\(r.result ?? r.error ?? "")")
        r = try script(app, "\(me) set «property SfEn» to false")
        #expect(r.ok, "\(r.error ?? "")")
        #expect(r.state?.phase == "off")
        #expect(try script(app, "\(me) get «property SfEn»").result == "false")
        _ = try script(app, "\(me) set «property SfEn» to true")
        #expect(try app.state().settings.enabled) // saved like the menu toggle

        // Commands.
        r = try script(app, "\(me) «event SfcsRNow»")
        #expect(r.ok, "\(r.error ?? "")")
        try app.waitFor("rest via AppleScript") { s, ui in s.phase == "resting" && ui.card != nil }
        r = try script(app, "\(me) «event SfcsSnze» given «class Mins»:2")
        #expect(r.ok, "\(r.error ?? "")")
        let (s, _) = try app.waitFor("snoozed") { _, ui in ui.card == nil }
        #expect(approx(s.secondsUntilRest, 120))
        _ = try script(app, "\(me) «event SfcsRsrt»")
        #expect(approx(try app.state().secondsUntilRest, 600))
        _ = try script(app, "\(me) «event SfcsRNow»")
        try app.waitFor("rest again") { s, _ in s.phase == "resting" }
        _ = try script(app, "\(me) «event SfcsFnsh»")
        try app.waitFor("finished via AppleScript") { s, ui in s.phase == "working" && ui.card == nil }

        // A bad argument is an AppleScript error, not a crash.
        r = try script(app, "\(me) «event SfcsSnze» given «class Mins»:0")
        #expect(!r.ok)
        #expect(try app.state().phase == "working")
    }

    /// Hooks can be AppleScripts, run through NSUserAppleScriptTask.
    @Test func appleScriptHooksRun() throws {
        let app = try RunningApp(settings: quickSettings(work: 600, rest: 30))
        defer { app.stop() }
        let log = app.workDir.appendingPathComponent("as-hook.log")
        let hook = app.workDir.appendingPathComponent("start.applescript")
        try "do shell script \"echo started >> \" & quoted form of \"\(log.path)\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try app.apply { $0.startHookPath = hook.path }
        try app.press(.menuRestNow)
        try app.waitFor("rest") { s, _ in s.phase == "resting" }
        #expect(eventually(timeout: 10) { (try? String(contentsOf: log, encoding: .utf8)) == "started\n" },
                "AppleScript hook did not run")
    }

    /// A shell script without the executable bit still runs (through /bin/sh).
    @Test func nonExecutableShellHookRuns() throws {
        let app = try RunningApp(settings: quickSettings(work: 600, rest: 30))
        defer { app.stop() }
        let (script, log) = try app.makeHookScript(name: "plain")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        try app.apply { $0.startHookPath = script.path }
        try app.press(.menuRestNow)
        #expect(eventually { (try? String(contentsOf: log, encoding: .utf8)) == "start start\n" })
    }
}

/// The app as users get it: no testing mode (standard limits, real sounds, real login item).
extension EndToEndTests {
    @Test func normalModeSmoke() throws {
        let app = try RunningApp(firstLaunch: true, env: ["SOFTFOCUS_TESTING": "0", "SOFTFOCUS_FAKE_IDLE": ""])
        defer { app.stop() }
        let (s, ui) = try app.waitFor("first launch") { _, ui in ui.settingsWindowVisible }
        #expect(s.phase == "working")
        #expect(approx(s.secondsUntilRest, 20 * 60, tolerance: 3))
        // Settings is open, so the app has a Dock icon for now.
        #expect(ui.statusItemVisible && ui.activationPolicy == "regular")
        // Reads the real login item without touching it.
        #expect(ui.loginItem == .disabled)
        // Standard limits apply outside testing mode.
        try app.apply { $0.restSeconds = 1; $0.workSeconds = 10 }
        let clamped = try app.state().settings
        #expect(clamped.restSeconds == 5 && clamped.workSeconds == 60)
        // A real rest with real sounds, then finish.
        try app.press(.menuRestNow)
        try app.waitFor("rest") { _, ui in ui.card != nil && ui.chimesPlayed.contains("restStart") }
        try app.press(.cardFinish)
        // Real idle time is in play here: if nobody is touching the Mac, the app rightly
        // goes to "idle" instead of starting the next work period.
        try app.waitFor("finished") { s, ui in ["working", "idle"].contains(s.phase) && ui.card == nil }
    }
}
