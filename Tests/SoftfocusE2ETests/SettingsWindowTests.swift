import AppKit
import ApplicationServices
import Foundation
import SoftfocusCore
import Testing

private let axReason: Comment = "needs an unlocked, awake screen and your terminal allowed under System Settings › Privacy & Security › Accessibility"

/// The Settings window, driven through its real controls via the accessibility API.
extension EndToEndTests {
    func openSettings(_ app: RunningApp) throws -> AXDriver {
        try app.press(.menuSettings)
        try app.waitFor("settings window") { _, ui in ui.settingsWindowVisible }
        let ax = AXDriver(pid: app.pid)
        _ = try ax.waitFor(SettingsID.enabled)
        return ax
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func settingsScheduleControls() throws {
        let app = try RunningApp(settings: quickSettings(work: 1200, rest: 20))
        defer { app.stop() }
        let ax = try openSettings(app)
        let work = SettingsID.workInterval, rest = SettingsID.restLength

        // Fields show the current values in the unit that fits.
        #expect(ax.text(work + ".field") == "20")
        #expect(ax.text(rest + ".field") == "20")
        #expect(ax.text(rest + ".unit") == "sec")

        // Presets: one click.
        try ax.press(work + ".preset.1800")
        try app.waitFor("work preset") { s, _ in s.settings.workSeconds == 1800 }
        #expect(approx(try app.state().secondsUntilRest, 1800, tolerance: 3))

        // Stepper: next multiple of 5 minutes.
        try ax.perform(work + ".stepper", kAXIncrementAction)
        try app.waitFor("work stepper") { s, _ in s.settings.workSeconds == 2100 }
        try ax.perform(work + ".stepper", kAXDecrementAction)
        try app.waitFor("work stepper down") { s, _ in s.settings.workSeconds == 1800 }

        // Typing: any exact value.
        try ax.type(work + ".field", "23")
        try app.waitFor("typed work") { s, _ in s.settings.workSeconds == 23 * 60 }

        // Rest presets switch the unit to fit the value.
        try ax.press(rest + ".preset.120")
        try app.waitFor("rest preset") { s, _ in s.settings.restSeconds == 120 }
        #expect(eventually { ax.text(rest + ".unit") == "min" && ax.text(rest + ".field") == "2" })
        try ax.type(rest + ".field", "3")
        try app.waitFor("typed rest") { s, _ in s.settings.restSeconds == 180 }
        try ax.perform(rest + ".stepper", kAXIncrementAction)
        try app.waitFor("rest stepper") { s, _ in s.settings.restSeconds == 240 }
        try ax.press(rest + ".preset.20")
        try app.waitFor("short rest") { s, _ in s.settings.restSeconds == 20 }
        #expect(eventually { ax.text(rest + ".unit") == "sec" })

        // The unit menu keeps the duration: 2 min shown as 120 sec, and back.
        try ax.press(rest + ".preset.120")
        try app.waitFor("2 min") { s, _ in s.settings.restSeconds == 120 }
        try ax.choose("sec", in: rest + ".unit")
        #expect(eventually { ax.text(rest + ".field") == "120" && ax.text(rest + ".unit") == "sec" })
        #expect(try app.state().settings.restSeconds == 120)
        try ax.choose("min", in: rest + ".unit")
        #expect(eventually { ax.text(rest + ".field") == "2" })
        #expect(try app.state().settings.restSeconds == 120)
        // Half-typed text survives using the stepper next: 7 is committed, then +1.
        try ax.typeWithoutCommit(rest + ".field", "7")
        try ax.perform(rest + ".stepper", kAXIncrementAction)
        try app.waitFor("typed then stepped") { s, _ in s.settings.restSeconds == 8 * 60 }

                // Out-of-range typing clamps (testing limits: rest ≤ 60 min).
        try ax.press(rest + ".preset.300")
        try app.waitFor("5 min") { s, _ in s.settings.restSeconds == 300 }
        try ax.type(rest + ".field", "500")
        try app.waitFor("clamped rest") { s, _ in s.settings.restSeconds == 3600 }
        #expect(eventually { ax.text(rest + ".field") == "60" })
        #expect(ax.exists(rest + ".note")) // tells the user the allowed range
        try ax.press(rest + ".preset.60")
        #expect(eventually { !ax.exists(rest + ".note") })
        try ax.type(rest + ".field", "60")
        try app.waitFor("back to 60 min") { s, _ in s.settings.restSeconds == 3600 }

        // Half-typed text in a focused field must not undo a preset or stepper click.
        try ax.typeWithoutCommit(work + ".field", "99")
        try ax.press(work + ".preset.2700")
        try app.waitFor("preset while editing") { s, _ in s.settings.workSeconds == 2700 }
        #expect(eventually { ax.text(work + ".field") == "45" })
        try ax.type(rest + ".field", "2") // moving on to another field commits the first
        Thread.sleep(forTimeInterval: 0.5)
        #expect(try app.state().settings.workSeconds == 2700)
        try ax.type(rest + ".field", "60")
        try app.waitFor("rest back") { s, _ in s.settings.restSeconds == 3600 }

        // Decimals are understood, not mangled ("1.5" is not 15).
        try ax.type(work + ".field", "22.5")
        try app.waitFor("rounded") { s, _ in s.settings.workSeconds == 23 * 60 }
        #expect(eventually { ax.text(work + ".note") == "Rounded to 23 min." })
        try ax.type(work + ".field", "23")

        // Heads-up and the master switch.
        try ax.press(SettingsID.headsUp)
        try app.waitFor("heads-up on") { s, _ in s.settings.headsUpSeconds == 10 }
        try ax.press(SettingsID.enabled)
        try app.waitFor("breaks off") { s, _ in s.phase == "off" && !s.settings.enabled }
        #expect(ax.isOn(SettingsID.enabled) == false)
        try ax.press(SettingsID.enabled)
        try app.waitFor("breaks on") { s, _ in s.phase == "working" }

        // Everything was saved.
        try app.relaunch()
        let s = try app.state().settings
        #expect(s.workSeconds == 23 * 60 && s.restSeconds == 3600 && s.headsUpSeconds == 10)
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func settingsAppearanceControls() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        let ax = try openSettings(app)
        try ax.press(SettingsID.dock)
        try app.waitFor("dock icon") { _, ui in ui.activationPolicy == "regular" }
        try ax.press(SettingsID.menuBar)
        try app.waitFor("no menu bar icon") { _, ui in !ui.statusItemVisible }
        #expect(!ax.exists(SettingsID.headlessNote))
        try ax.press(SettingsID.dock)
        try app.waitFor("headless") { s, ui in s.settings.isHeadless && ui.activationPolicy == "accessory" }
        #expect(eventually { ax.exists(SettingsID.headlessNote) })
        try ax.press(SettingsID.menuBar)
        try app.waitFor("menu bar back") { _, ui in ui.statusItemVisible }
        #expect(eventually { !ax.exists(SettingsID.headlessNote) })
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func settingsRestTab() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        let ax = try openSettings(app)
        try ax.selectTab("Rest")
        try ax.press(SettingsID.strict)
        try ax.press(SettingsID.autoFinish)
        try ax.press(SettingsID.sounds)
        try ax.press(SettingsID.smartReset)
        let (s, _) = try app.waitFor("rest options") { s, _ in s.settings.strictMode }
        #expect(s.settings.autoFinish && !s.settings.soundsOn && !s.settings.smartReset)

        // Strict mode from the window really changes the rest.
        try app.press(.menuRestNow)
        let (rest, _) = try app.waitFor("strict rest") { s, ui in ui.card != nil && s.focusLocked }
        #expect(!rest.canSnooze && !rest.canFinish)
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func settingsScriptsTab() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        let hook = try app.makeHookScript(name: "start")
        try app.apply { $0.startHookPath = hook.script.path }
        let ax = try openSettings(app)
        try ax.selectTab("Scripts")
        let path = SettingsID.hook(.start, "path")
        _ = try ax.waitFor(path)
        #expect(ax.text(path) == "start.sh")
        #expect(ax.text(SettingsID.hook(.end, "path")) == "Nothing")
        // "Choose…" opens a file dialog; cancelling it changes nothing.
        try ax.press(SettingsID.hook(.end, "choose"))
        let dialog = try #require(ax.dialog(withButton: "Cancel"), "no file dialog")
        AXUIElementPerformAction(dialog.button, kAXPressAction as CFString)
        #expect(eventually { ax.dialog(withButton: "Cancel", timeout: 0) == nil })
        #expect(try app.state().settings.endHookPath == nil)

        try ax.press(SettingsID.hook(.start, "clear"))
        try app.waitFor("hook cleared") { s, _ in s.settings.startHookPath == nil }
        #expect(eventually { ax.text(path) == "Nothing" && !ax.exists(SettingsID.hook(.start, "clear")) })
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func settingsScreenshots() throws {
        let app = try RunningApp(settings: quickSettings(work: 1200, rest: 20))
        defer { app.stop() }
        try app.press(.menuSettings)
        try app.waitFor("settings window") { _, ui in ui.settingsWindowVisible }
        Thread.sleep(forTimeInterval: 0.5)
        let ax = AXDriver(pid: app.pid)
        for tab in ["General", "Rest", "Scripts"] {
            if tab != "General" {
                try ax.selectTab(tab)
                Thread.sleep(forTimeInterval: 0.5)
            }
            let png = RunningApp.artifactsDir.appendingPathComponent("settings-\(tab.lowercased()).png")
            #expect(try app.send(.init(.renderSettings, path: png.path)).ok)
            #expect((try? Data(contentsOf: png).count) ?? 0 > 10_000)
        }
    }
}

/// "Open at login". macOS owns the truth; the toggle follows it.
extension EndToEndTests {
    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func openAtLoginRegistersAndFollowsSystemSettings() throws {
        let app = try RunningApp(settings: quickSettings())
        defer { app.stop() }
        let ax = try openSettings(app)
        #expect(ax.isOn(SettingsID.launchAtLogin) == false)

        try ax.press(SettingsID.launchAtLogin)
        let (s, ui) = try app.waitFor("registered") { s, ui in ui.loginItem == .enabled && s.settings.launchAtLogin }
        #expect(s.settings.launchAtLogin && ui.loginItemMessage == nil)
        #expect(!ax.exists(SettingsID.loginItemNote))

        // The user switches Softfocus off in System Settings › Login Items.
        // The app notices the next time it is brought up (here: Settings reopened).
        #expect(try app.send(.init(.loginItem, key: LoginItemState.disabled.rawValue)).ok)
        try app.press(.menuSettings)
        try app.waitFor("follows macOS") { s, _ in !s.settings.launchAtLogin }
        #expect(eventually { ax.isOn(SettingsID.launchAtLogin) == false })

        // And on launch: a stale "on" in our own defaults gives way to what macOS says.
        try app.apply { $0.launchAtLogin = true }
        try app.waitFor("on") { _, ui in ui.loginItem == .enabled }
        #expect(try app.send(.init(.loginItem, key: LoginItemState.disabled.rawValue)).ok)
        try app.relaunch()
        #expect(try !app.state().settings.launchAtLogin)
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func openAtLoginWaitingForApproval() throws {
        let app = try RunningApp(settings: quickSettings(), env: ["SOFTFOCUS_FAKE_LOGIN": "requiresApproval"])
        defer { app.stop() }
        let ax = try openSettings(app)
        try ax.press(SettingsID.launchAtLogin)
        let (s, _) = try app.waitFor("needs approval") { _, ui in ui.loginItem == .requiresApproval }
        #expect(s.settings.launchAtLogin) // the toggle stays on: the user asked for it
        _ = try ax.waitFor(SettingsID.loginItemNote)
        try ax.press(SettingsID.openLoginItems)
        try app.waitFor("login items opened") { _, ui in ui.loginItemSettingsOpened == 1 }

        // The user approves it in System Settings; the note goes away.
        #expect(try app.send(.init(.loginItem, key: LoginItemState.enabled.rawValue)).ok)
        try app.press(.menuSettings)
        #expect(eventually { !ax.exists(SettingsID.loginItemNote) })
    }

    @Test(.enabled(if: ScreenState.canDriveUI, axReason))
    func openAtLoginErrorIsShownAndToggleReverts() throws {
        let app = try RunningApp(settings: quickSettings(), env: ["SOFTFOCUS_FAKE_LOGIN": "fail"])
        defer { app.stop() }
        let ax = try openSettings(app)
        try ax.press(SettingsID.launchAtLogin)
        let (s, ui) = try app.waitFor("error shown") { _, ui in ui.loginItemMessage != nil }
        #expect(!s.settings.launchAtLogin && ui.loginItem == .disabled)
        #expect(ui.loginItemMessage?.hasPrefix("Could not change the login item") == true)
        #expect(eventually { ax.exists(SettingsID.loginItemNote) && ax.isOn(SettingsID.launchAtLogin) == false })
    }

    /// Registers the built app with macOS for real, then removes it again.
    /// Opt-in (SOFTFOCUS_E2E_REAL_LOGIN=1): macOS shows a "Login item added" notification.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOFTFOCUS_E2E_REAL_LOGIN"] == "1" && ScreenState.canDriveUI))
    func openAtLoginWithRealMacOS() throws {
        let app = try RunningApp(settings: quickSettings(), env: ["SOFTFOCUS_REAL_LOGIN_ITEM": "1"])
        defer {
            try? app.apply { $0.launchAtLogin = false }
            app.stop()
        }
        let before = try app.ui().loginItem
        try #require(before == .disabled, "Softfocus is already a login item; remove it first")
        let ax = try openSettings(app)
        try ax.press(SettingsID.launchAtLogin)
        let (_, on) = try app.waitFor("registered with macOS") { _, ui in ui.loginItem != .disabled || ui.loginItemMessage != nil }
        #expect(on.loginItemMessage == nil, "\(on.loginItemMessage ?? "")")
        #expect(on.loginItem == .enabled || on.loginItem == .requiresApproval)
        try ax.press(SettingsID.launchAtLogin)
        try app.waitFor("unregistered") { s, ui in ui.loginItem == .disabled && !s.settings.launchAtLogin }
    }
}
