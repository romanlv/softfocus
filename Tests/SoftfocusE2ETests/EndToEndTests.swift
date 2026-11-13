import AppKit
import Foundation
import SoftfocusCore
import Testing

/// Runs against the real, built Softfocus.app. Rest overlays appear on screen briefly.
/// Run with scripts/test-e2e.sh (sets SOFTFOCUS_APP).
@Suite("End to end", .serialized, .enabled(if: RunningApp.isAvailable, "set SOFTFOCUS_APP to a built Softfocus.app"))
struct EndToEndTests {
    static let shieldLevel = 999   // just below the screen-saver window level
    static let cardLevel = 1000
    static let strictOptions: UInt = 2 | 8 | 32 | 64 | 256 // hideDock, hideMenuBar, no switching, no force quit, no hide

    @Test func launchesIntoMenuBarAndCountsDown() throws {
        let app = try RunningApp(settings: quickSettings(work: 120))
        defer { app.stop() }
        let s = try app.state()
        #expect(s.phase == "working")
        #expect(approx(s.secondsUntilRest, 120, tolerance: 3))
        let ui = try app.ui()
        #expect(ui.statusItemVisible)
        #expect(ui.activationPolicy == "accessory")
        #expect(ui.menuItems.contains("Rest Now"))
        #expect(ui.menuItems.first?.hasPrefix("Next rest in") == true)
        #expect(ui.shields.isEmpty && ui.card == nil)
        #expect(!ui.settingsWindowVisible)
    }

    @Test func firstLaunchOpensSettings() throws {
        let app = try RunningApp(firstLaunch: true)
        defer { app.stop() }
        try app.waitFor("settings window") { _, ui in ui.settingsWindowVisible }
        try app.relaunch()
        Thread.sleep(forTimeInterval: 0.5)
        #expect(try !app.ui().settingsWindowVisible)
    }

    @Test func fullCycleWithHeadsUpHooksAndFinish() throws {
        let app = try RunningApp(settings: quickSettings(work: 3, rest: 2) { $0.headsUpSeconds = 1.5 })
        defer { app.stop() }
        let start = try app.makeHookScript(name: "start")
        let end = try app.makeHookScript(name: "end")
        try app.apply { $0.startHookPath = start.script.path; $0.endHookPath = end.script.path; $0.workSeconds = 3 }

        // Heads-up panel shows a countdown shortly before the rest.
        let (_, heads) = try app.waitFor("heads-up") { _, ui in ui.headsUp != nil }
        #expect(heads.headsUpText?.hasPrefix("Rest in 00:0") == true)

        // Rest: a shield on every display plus the card, which takes keyboard focus.
        let (state, ui) = try app.waitFor("rest") { s, ui in s.phase == "resting" && ui.card != nil }
        #expect(ui.headsUp == nil)
        #expect(ui.shields.count == ui.screens.count)
        for (shield, screen) in zip(ui.shields, ui.screens) {
            #expect(shield.frame == screen)
            #expect(shield.level == Self.shieldLevel)
        }
        let card = try #require(ui.card)
        #expect(card.window.level == Self.cardLevel)
        if ScreenState.isUsable { #expect(card.window.isKey) } // a locked screen has no key window
        #expect(card.headline == "Time to rest your eyes")
        #expect(card.snoozeEnabled && card.finishEnabled)
        #expect(card.snoozeMenu == ["Snooze 1 minute", "Snooze 5 minutes", "Snooze 15 minutes"])
        #expect(state.canSnooze && state.canFinish)
        #expect(ui.chimesPlayed.contains("restStart"))

        // The window server agrees: shield and card windows are really on screen.
        #expect(eventually {
            let windows = app.onScreenWindows()
            return windows.filter { $0.layer == Self.shieldLevel }.count == ui.screens.count
                && windows.contains { $0.layer == Self.cardLevel }
        }, "window server sees: \(app.onScreenWindows())")

        let png = RunningApp.artifactsDir.appendingPathComponent("rest-card.png")
        #expect(try app.send(.init(.renderCard, path: png.path)).ok)
        #expect((try? Data(contentsOf: png).count) ?? 0 > 1000)

        // Rest time runs out: card switches to "complete", reminder chime loops.
        let (doneState, doneUI) = try app.waitFor("rest complete") { s, _ in s.phase == "restDone" }
        #expect(doneUI.card?.remaining == "00:00")
        #expect(doneUI.card?.headline == "Rest complete")
        #expect(doneUI.card?.progress == 1)
        #expect(doneState.chimeLooping)
        #expect(try app.send(.init(.renderCard, path: RunningApp.artifactsDir.appendingPathComponent("rest-card-complete.png").path)).ok)

        // Finish closes everything and starts a fresh work period.
        #expect(try app.press(.cardFinish).ok)
        let (after, afterUI) = try app.waitFor("closed") { _, ui in ui.card == nil && ui.shields.isEmpty }
        #expect(after.phase == "working")
        #expect(!after.chimeLooping)
        #expect(approx(after.secondsUntilRest, 3))
        // The window server catches up a moment after orderOut.
        #expect(eventually { app.onScreenWindows().allSatisfy { $0.layer != Self.shieldLevel && $0.layer != Self.cardLevel } },
                "overlay windows still on screen: \(app.onScreenWindows())")

        // Both hooks really ran, with the hook name as argument and in the environment.
        let read = { (u: URL) in (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        #expect(eventually { read(start.log) == "start start\n" && read(end.log) == "end end\n" },
                "start log: \(read(start.log).debugDescription), end log: \(read(end.log).debugDescription)")
        #expect(afterUI.hooksRun.count == 2)
    }

    @Test func snoozeFromSplitButtonAndItsMenu() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        for (target, seconds) in [(ControlTarget.cardSnooze, 60.0), (.cardSnooze5, 300), (.cardSnooze15, 900)] {
            #expect(try app.press(.menuRestNow).ok)
            try app.waitFor("rest") { _, ui in ui.card != nil }
            #expect(try app.press(target).ok)
            let (s, ui) = try app.waitFor("snoozed") { s, _ in s.phase == "working" }
            #expect(approx(s.secondsUntilRest, seconds), "\(target)")
            #expect(ui.card == nil && ui.shields.isEmpty)
        }
    }

    @Test func keyboardShortcutsOnTheCard() throws {
        let app = try RunningApp(settings: quickSettings(work: 600))
        defer { app.stop() }

        try app.press(.menuRestNow)
        try app.waitFor("rest") { _, ui in ui.card != nil }
        // Return right away is ignored, so a keystroke in flight cannot dismiss the rest.
        #expect(try app.key("return").ok)
        #expect(try app.state().phase == "resting")
        // Shift-Esc snoozes 5 minutes.
        #expect(try app.key("escape", shift: true).ok)
        #expect(approx(try app.state().secondsUntilRest, 300))

        try app.press(.menuRestNow)
        try app.waitFor("rest") { _, ui in ui.card != nil }
        #expect(try app.key("escape").ok)
        #expect(approx(try app.state().secondsUntilRest, 60))

        try app.press(.menuRestNow)
        try app.waitFor("rest") { _, ui in ui.card != nil }
        Thread.sleep(forTimeInterval: 0.6)
        #expect(try app.key("space").ok)
        let s = try app.state()
        #expect(s.phase == "working")
        #expect(approx(s.secondsUntilRest, 600))
    }

    @Test func strictModeLocksUntilTheRestIsOver() throws {
        let app = try RunningApp(settings: quickSettings(rest: 5) { $0.strictMode = true })
        defer { app.stop() }

        try app.press(.menuRestNow)
        let (s, ui) = try app.waitFor("strict rest") { s, ui in ui.card != nil && s.focusLocked }
        #expect(!s.canSnooze && !s.canFinish && !s.canQuit)
        #expect(ui.presentationOptions == Self.strictOptions)
        #expect(ui.card?.snoozeEnabled == false && ui.card?.finishEnabled == false)

        // Every way out is refused.
        #expect(try !app.press(.cardFinish).ok)
        #expect(try !app.press(.cardSnooze).ok)
        #expect(try !app.press(.cardSnooze5).ok)
        #expect(try !app.press(.menuQuit).ok)
        #expect(try !app.press(.menuToggle).ok)
        _ = try app.key("escape")
        Thread.sleep(forTimeInterval: 0.6)
        _ = try app.key("return")
        #expect(app.process.isRunning)
        // Nor can a script or link switch breaks off, or a screen lock end it.
        #expect(try app.send(.init(.url, path: "softfocus://disable")).ok)
        _ = try app.send(.init(.appleScript, path: "tell application id \"app.softfocus.Softfocus\" to set «property SfEn» to false"))
        try app.send(.init(.presence, away: true))
        try app.send(.init(.presence, away: false))
        let still = try app.state()
        #expect(still.phase == "resting" && still.focusLocked && !still.canFinish)
        try app.apply { $0.enabled = true } // undo the "off" requests, which would apply after the rest
        // Settings (where the rest could be shortened) stays shut until the rest is over.
        try app.press(.menuSettings)
        _ = try app.send(.init(.url, path: "softfocus://settings"))
        #expect(try !app.ui().settingsWindowVisible)
        // Even a direct settings change can't make it non-strict or shorter.
        try app.apply { $0.strictMode = false; $0.restSeconds = 1 }
        let kept = try app.state()
        #expect(kept.focusLocked && !kept.canSnooze && !kept.canFinish && kept.phase == "resting")
        try app.apply { $0.strictMode = true; $0.restSeconds = 5 }

        // Once time is up, Finish (only) becomes available and unlocks.
        let (_, doneUI) = try app.waitFor("strict rest complete") { s, _ in s.phase == "restDone" }
        #expect(doneUI.card?.finishEnabled == true && doneUI.card?.snoozeEnabled == false)
        #expect(doneUI.presentationOptions == Self.strictOptions)
        #expect(try app.press(.cardFinish).ok)
        let (after, afterUI) = try app.waitFor("unlocked") { s, _ in s.phase == "working" }
        #expect(!after.focusLocked && after.canQuit)
        #expect(afterUI.presentationOptions == 0)
    }

    @Test func autoFinishClosesTheCardItself() throws {
        let app = try RunningApp(settings: quickSettings(rest: 1.5) { $0.autoFinish = true })
        defer { app.stop() }
        try app.press(.menuRestNow)
        try app.waitFor("rest") { _, ui in ui.card != nil }
        let (s, ui) = try app.waitFor("auto finish") { s, ui in s.phase == "working" && ui.card == nil }
        #expect(ui.shields.isEmpty)
        #expect(ui.chimesPlayed.contains("restEnd"))
        #expect(!ui.chimesPlayed.contains("loop"))
        #expect(approx(s.secondsUntilRest, 60, tolerance: 2))
    }

    @Test func idleTimeCountsAsRest() throws {
        let app = try RunningApp(settings: quickSettings(work: 60, rest: 30))
        defer { app.stop() }
        Thread.sleep(forTimeInterval: 2)
        #expect(try app.state().secondsUntilRest! < 59)
        // Nobody at the Mac long enough: paused, with no rest card for an empty desk.
        #expect(try app.send(.init(.idle, seconds: 10_000)).ok)
        let (_, ui) = try app.waitFor("paused while idle") { s, _ in s.phase == "idle" }
        #expect(ui.menuItems.first == "Paused while you are away" && ui.card == nil)
        // First input: a full work period from now.
        try app.send(.init(.idle, seconds: 0))
        let (s, _) = try app.waitFor("back") { s, _ in s.phase == "working" }
        #expect(approx(s.secondsUntilRest, 60))
    }

    @Test func idleBeforeDueTimeCountsTowardsTheRest() throws {
        let app = try RunningApp(settings: quickSettings(work: 3, rest: 30))
        defer { app.stop() }
        #expect(try app.send(.init(.idle, seconds: 20)).ok)
        let (_, ui) = try app.waitFor("rest with credit") { _, ui in ui.card != nil }
        let rested = try #require(ui.card?.elapsed)
        #expect(rested >= "00:20", "card started at \(rested)")
        try app.send(.init(.idle, seconds: 0))
    }

    @Test func sleepOrLockPausesWorkButNotARest() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        // Locked during a rest: that is resting; the card stays.
        try app.press(.menuRestNow)
        try app.waitFor("rest") { _, ui in ui.card != nil }
        try app.send(.init(.presence, away: true))
        #expect(try app.ui().card != nil && app.state().phase == "resting")
        try app.send(.init(.presence, away: false))
        try app.press(.cardFinish)
        try app.waitFor("finished") { s, ui in s.phase == "working" && ui.card == nil }

        // Locked while working: paused; a fresh work period starts on return.
        try app.send(.init(.presence, away: true))
        let (_, ui) = try app.waitFor("away") { s, _ in s.phase == "away" }
        #expect(ui.menuItems.first == "Paused while you are away")
        Thread.sleep(forTimeInterval: 1)
        try app.send(.init(.presence, away: false))
        let s = try app.state()
        #expect(s.phase == "working" && approx(s.secondsUntilRest, 60))
    }

    @Test func menuToggleAndPostponePersist() throws {
        let app = try RunningApp(settings: quickSettings(work: 600))
        defer { app.stop() }
        #expect(try app.press(.menuPostpone).ok)
        #expect(approx(try app.state().secondsUntilRest, 900))
        #expect(try app.press(.menuRestart).ok)
        #expect(approx(try app.state().secondsUntilRest, 600))

        #expect(try app.press(.menuToggle).ok)
        #expect(try app.state().phase == "off")
        #expect(try app.ui().menuItems.first == "Breaks are off")

        try app.relaunch()
        #expect(try app.state().phase == "off", "disabled state should survive a relaunch")
        #expect(try app.press(.menuToggle).ok)
        #expect(try app.state().phase == "working")
    }

    @Test func dockAndMenuBarVisibility() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        try app.apply { $0.showInDock = true }
        try app.waitFor("dock icon") { _, ui in ui.activationPolicy == "regular" }
        try app.apply { $0.showInMenuBar = false }
        try app.waitFor("menu bar hidden") { _, ui in !ui.statusItemVisible }

        try app.relaunch()
        let ui = try app.ui()
        #expect(ui.activationPolicy == "regular" && !ui.statusItemVisible)

        // With neither, launching opens Settings so the app stays reachable.
        try app.apply { $0.showInDock = false }
        try app.relaunch()
        try app.waitFor("settings shown for headless app") { _, ui in ui.settingsWindowVisible }
    }

    @Test func settingsAreClampedAndPersisted() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        try app.apply { $0.restSeconds = 0; $0.workSeconds = 999_999 }
        let s = try app.state().settings
        #expect(s.restSeconds == 1) // testing limits floor
        #expect(s.workSeconds == 14_400)
        try app.relaunch()
        #expect(try app.state().settings.restSeconds == 1)
    }

    @Test func urlCommands() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        #expect(try app.send(.init(.url, path: "softfocus://rest-now")).ok)
        try app.waitFor("rest") { _, ui in ui.card != nil }
        #expect(try app.send(.init(.url, path: "softfocus://snooze?minutes=2")).ok)
        #expect(approx(try app.state().secondsUntilRest, 120))
        #expect(try app.send(.init(.url, path: "softfocus://disable")).ok)
        #expect(try app.state().phase == "off")
        #expect(try app.send(.init(.url, path: "softfocus://toggle")).ok)
        #expect(try app.state().phase == "working")
        #expect(try !app.send(.init(.url, path: "softfocus://nonsense")).ok)
    }

    @Test func quitFromMenu() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        #expect(try app.press(.menuQuit).ok)
        let deadline = Date() + 5
        while app.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(!app.process.isRunning)
        #expect(app.process.terminationReason == .exit)
    }
}
