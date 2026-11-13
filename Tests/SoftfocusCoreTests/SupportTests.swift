import Foundation
import Testing
@testable import SoftfocusCore

@Suite("Formatting")
struct FormattingTests {
    @Test(arguments: [(0.0, "00:00"), (12.7, "00:12"), (168, "02:48"), (3725, "1:02:05"), (-5, "00:00")])
    func digital(_ seconds: Double, _ text: String) {
        #expect(TimeText.digital(seconds) == text)
    }

    @Test(arguments: [(44.2, "45 sec"), (60.0, "1 min"), (61, "2 min"), (3600, "1 hr"), (5400, "1.5 hr")])
    func approximate(_ seconds: Double, _ text: String) {
        #expect(TimeText.approximate(seconds) == text)
    }

    @Test func statusLines() {
        var d = Driver()
        #expect(d.cycle.statusLine(at: d.now) == "Next rest in 10 min")
        d.send(.restNow)
        #expect(d.cycle.statusLine(at: d.now) == "Resting, 01:00 left")
        d.send(.finish)
        d.send(.presence(away: true))
        #expect(d.cycle.statusLine(at: d.now) == "Paused while you are away")
        d.send(.setEnabled(false))
        #expect(d.cycle.statusLine(at: d.now) == "Breaks are off")
    }
}

@Suite("Keyboard")
struct KeyboardTests {
    @Test func escapeSnoozesShiftEscapeSnoozesLonger() {
        var d = Driver()
        d.send(.restNow)
        #expect(RestKeys.action(for: .escape, shift: false, cardShownFor: 0, cycle: d.cycle) == .snooze(60))
        #expect(RestKeys.action(for: .escape, shift: true, cardShownFor: 0, cycle: d.cycle) == .snooze(300))
    }

    @Test func returnAndSpaceFinishOnlyAfterGuard() {
        var d = Driver()
        d.send(.restNow)
        #expect(RestKeys.action(for: .returnKey, shift: false, cardShownFor: 0.2, cycle: d.cycle) == nil)
        #expect(RestKeys.action(for: .returnKey, shift: false, cardShownFor: 0.6, cycle: d.cycle) == .finish)
        #expect(RestKeys.action(for: .space, shift: false, cardShownFor: 0.6, cycle: d.cycle) == .finish)
        #expect(RestKeys.action(for: .other, shift: false, cardShownFor: 5, cycle: d.cycle) == nil)
    }

    @Test func strictIgnoresKeysUntilDone() {
        var d = Driver { $0.strictMode = true }
        d.send(.restNow)
        #expect(RestKeys.action(for: .escape, shift: false, cardShownFor: 5, cycle: d.cycle) == nil)
        #expect(RestKeys.action(for: .returnKey, shift: false, cardShownFor: 5, cycle: d.cycle) == nil)
        d.advance(60)
        #expect(RestKeys.action(for: .returnKey, shift: false, cardShownFor: 61, cycle: d.cycle) == .finish)
        #expect(RestKeys.action(for: .escape, shift: false, cardShownFor: 61, cycle: d.cycle) == nil)
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func clampsToLimits() {
        var s = Settings()
        s.workSeconds = 5
        s.restSeconds = 1
        s.headsUpSeconds = 999
        s.startHookPath = ""
        let c = s.clamped(to: .standard)
        #expect(c.workSeconds == 60 && c.restSeconds == 5 && c.headsUpSeconds == 60)
        #expect(c.startHookPath == nil)
        #expect(s.clamped(to: .testing).workSeconds == 5)
    }

    @Test func roundTripsThroughDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("softfocus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try #require(UserDefaults(suiteName: dir.appendingPathComponent("defaults").path))
        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == Settings())
        var s = Settings()
        s.strictMode = true
        s.workSeconds = 1800
        s.endHookPath = "/tmp/x.sh"
        store.save(s)
        #expect(SettingsStore(defaults: defaults).load() == s)
        #expect(store.consumeFirstLaunch())
        #expect(!store.consumeFirstLaunch())
    }

    @Test func missingKeysUseDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"strictMode":true}"#.utf8))
        var expected = Settings()
        expected.strictMode = true
        #expect(s == expected)
    }

    @Test func headlessDetection() {
        var s = Settings()
        #expect(!s.isHeadless)
        s.showInMenuBar = false
        #expect(s.isHeadless)
    }

}

@Suite("Duration fields")
struct DurationFieldTests {
    let work = DurationField.work(.standard)
    let rest = DurationField.rest(.standard)

    @Test func showsWholeMinutesInMinutes() {
        #expect(rest.unit(for: 120) == .minutes)
        #expect(rest.unit(for: 90) == .seconds)
        #expect(rest.unit(for: 30) == .seconds)
        #expect(work.unit(for: 90) == .minutes) // work is minutes only
        #expect(rest.label(120) == "2 min" && rest.label(45) == "45 sec")
    }

    @Test func typedValuesAreExactButClamped() {
        #expect(work.seconds(amount: 23, unit: .minutes) == 23 * 60)
        #expect(work.seconds(amount: 0, unit: .minutes) == 60)
        #expect(work.seconds(amount: 999, unit: .minutes) == 4 * 3600)
        #expect(rest.seconds(amount: 37, unit: .seconds) == 37)
        #expect(rest.seconds(amount: 2, unit: .seconds) == 5)
    }

    @Test func stepperMovesToNextRoundValue() {
        #expect(work.stepped(20 * 60, unit: .minutes, up: true) == 25 * 60)
        #expect(work.stepped(22 * 60, unit: .minutes, up: true) == 25 * 60)
        #expect(work.stepped(22 * 60, unit: .minutes, up: false) == 20 * 60)
        #expect(work.stepped(5 * 60, unit: .minutes, up: false) == 60) // down to the minimum
        #expect(work.stepped(60, unit: .minutes, up: false) == 60)
        #expect(rest.stepped(60, unit: .minutes, up: false) == 55) // carries on in seconds
        #expect(rest.stepped(5, unit: .seconds, up: false) == 5)
        #expect(rest.stepped(20, unit: .seconds, up: true) == 25)
        #expect(rest.stepped(2 * 60, unit: .minutes, up: false) == 60)
        #expect(rest.stepped(3600, unit: .minutes, up: true) == 3600) // top of range
    }

    @Test func changingUnitKeepsTheDuration() {
        #expect(rest.changingUnit(120, from: .minutes, to: .seconds) == 120) // shown as "120 sec"
        #expect(rest.changingUnit(90, from: .seconds, to: .minutes) == 120)  // whole minutes only
        #expect(rest.changingUnit(20, from: .seconds, to: .minutes) == 60)
    }

    @Test func parsingTypedText() {
        #expect(work.parse("23", unit: .minutes) == .init(seconds: 1380, note: nil))
        #expect(work.parse(" 1.5 ", unit: .minutes) == .init(seconds: 120, note: "Rounded to 2 min."))
        #expect(rest.parse("1,5", unit: .minutes) == .init(seconds: 90, note: nil))
        #expect(rest.parse("2.4", unit: .seconds) == .init(seconds: 5, note: "Choose between 5 sec – 60 min."))
        #expect(rest.parse("500", unit: .minutes).seconds == 3600)
        #expect(rest.parse("abc", unit: .seconds) == .init(seconds: nil, note: "Type a number, like 20."))
        #expect(rest.parse("", unit: .seconds).seconds == nil)
        #expect(work.parse("-5", unit: .minutes).seconds == 60)
    }

    @Test func rangeText() {
        #expect(rest.rangeText == "5 sec – 60 min")
        #expect(work.rangeText == "1 min – 240 min")
    }
}

@Suite("External commands")
struct ExternalCommandTests {
    @Test(arguments: [
        ("softfocus://rest-now", ExternalCommand.restNow),
        ("softfocus://finish", .finish),
        ("softfocus://snooze?minutes=5", .snooze(300)),
        ("softfocus://snooze", .snooze(60)),
        ("softfocus://enable", .setEnabled(true)),
        ("softfocus://disable", .setEnabled(false)),
        ("SOFTFOCUS://toggle", .toggle),
        ("softfocus://restart", .restartCountdown),
        ("softfocus://settings", .openSettings),
    ])
    func parses(_ url: String, _ command: ExternalCommand) {
        #expect(ExternalCommand(url: URL(string: url)!) == command)
    }

    @Test(arguments: ["https://rest-now", "softfocus://explode", "softfocus://snooze?minutes=0"])
    func rejects(_ url: String) {
        #expect(ExternalCommand(url: URL(string: url)!) == nil)
    }

    @Test func toggleFlipsEnabled() {
        let d = Driver()
        #expect(ExternalCommand.toggle.event(given: d.cycle) == .setEnabled(false))
        #expect(ExternalCommand.openSettings.event(given: d.cycle) == nil)
    }
}

@Suite("Control channel")
struct ControlChannelTests {
    @Test func requestResponseRoundTrip() throws {
        let path = NSTemporaryDirectory() + "rc-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: path) { req in
            ControlResponse(ok: req.cmd == .state, error: req.target)
        }
        try server.start()
        defer { server.stop() }
        let client = try ControlClient(path: path)
        #expect(try client.send(.init(.state)).ok)
        let r = try client.send(.init(.press, target: "card.finish"))
        #expect(!r.ok && r.error == "card.finish")
    }

    @Test func settingsSurviveEncoding() throws {
        var s = Settings()
        s.restSeconds = 42
        let req = ControlRequest(.settings, settings: s)
        let back = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(req))
        #expect(back == req)
    }
}
