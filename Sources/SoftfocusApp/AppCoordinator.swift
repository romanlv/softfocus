import AppKit
import SoftfocusCore

/// Owns the cycle and connects it to windows, menu bar and system services.
/// Every input becomes a `Cycle` event; every `Effect` is carried out here.
@MainActor
public final class AppCoordinator: NSObject, NSApplicationDelegate {
    public static private(set) weak var shared: AppCoordinator?

    let config: AppConfig
    let store: SettingsStore
    private(set) var cycle: Cycle
    let clock: () -> Date

    let idle: SystemIdleSource
    let focus: FocusLocking
    let chimes: ChimePlaying
    let hooks = HookRunner()
    let loginItem: LoginItemControlling
    let overlay = RestOverlayController()
    let headsUp = HeadsUpController()
    private(set) var statusItem: StatusItemController?
    let settingsModel: SettingsModel
    private(set) lazy var settingsWindow = SettingsWindowController(model: settingsModel)
    private var presence: PresenceMonitor?
    private var control: ControlServer?
    private var timers: [Timer] = []
    private var scriptResult: String?
    private var napGuard: NSObjectProtocol?
    private var awaySince: Date?

    /// Test-visible log of what actually ran.
    private(set) var hooksRun: [String] = []
    private(set) var chimesPlayed: [String] = []

    public init(config: AppConfig, clock: @escaping () -> Date = Date.init) {
        self.config = config
        self.clock = clock
        let defaults = config.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        store = SettingsStore(defaults: defaults, limits: config.testing ? .testing : .standard)
        let settings = store.load()
        cycle = Cycle(settings: settings, now: clock())
        idle = SystemIdleSource()
        idle.override = config.idleOverride
        focus = PresentationFocusLock()
        chimes = config.testing ? SilentChimePlayer() : SystemChimePlayer()
        if config.testing && !config.realLoginItem {
            loginItem = FakeLoginItem(registerAnswer: config.fakeLoginAnswer.flatMap(FakeLoginItem.Answer.init) ?? .enabled)
        } else {
            loginItem = SystemLoginItem()
        }
        settingsModel = SettingsModel(settings: settings)
        settingsModel.limits = store.limits
        super.init()
        Self.shared = self
    }

    // MARK: Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // A menu-bar app is "invisible" to App Nap, which would delay our timers by
        // many seconds. Rests must start on time, so opt out (idle sleep still allowed).
        napGuard = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Timing rest reminders")

        let status = StatusItemController()
        status.snapshot = { [unowned self] in (cycle, clock()) }
        status.onAction = { [unowned self] in perform($0) }
        statusItem = status

        overlay.onSnooze = { [unowned self] in send(.snooze($0)) }
        overlay.onFinish = { [unowned self] in send(.finish) }
        overlay.onKey = { [unowned self] key, shift, shownFor in
            guard let action = RestKeys.action(for: key, shift: shift, cardShownFor: shownFor, cycle: cycle) else { return }
            switch action {
            case .snooze(let s): send(.snooze(s))
            case .finish: send(.finish)
            }
        }
        headsUp.onSnooze = { [unowned self] in send(.snooze(5 * 60)) }
        headsUp.onRestNow = { [unowned self] in send(.restNow) }

        settingsModel.onChange = { [unowned self] in updateSettings($0) }
        settingsModel.onOpenLoginItems = { [unowned self] in loginItem.openSystemSettings() }
        settingsWindow.onShow = { [unowned self] in refreshLoginItem() }
        settingsWindow.onClose = { [unowned self] in applyAppearance(cycle.settings) }
        // The user may have changed the login item in System Settings meanwhile.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLoginItem() }
        }

        let presence = PresenceMonitor { [unowned self] away in send(.presence(away: away)) }
        presence.start()
        self.presence = presence

        applyAppearance(cycle.settings)
        refreshLoginItem()
        startTimers()
        startControlChannel()

        if store.consumeFirstLaunch() || cycle.settings.isHeadless {
            settingsWindow.show()
        }
        render()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Strict mode blocks the user's Quit, never a logout, restart or shutdown.
        cycle.canQuit || Self.isSystemQuit() ? .terminateNow : .terminateCancel
    }

    /// True when the quit request comes from logout/restart/shutdown (the Apple event
    /// carries a quit reason then).
    static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.paramDescriptor(forKeyword: kAEQuitReason)
                ?? event.attributeDescriptor(forKeyword: kAEQuitReason) else { return false }
        return reason.enumCodeValue != 0
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if cycle.focusLocked { focus.unlock() }
        control?.stop()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = handle(url: url) }
    }

    // MARK: Event loop

    /// Feeds one event into the cycle, performs its effects and refreshes the UI.
    func send(_ event: Event) {
        let effects = cycle.handle(event, at: clock())
        effects.forEach(apply)
        render()
    }

    private func startTimers() {
        // Idle time is sampled on every tick (a cheap call), so the cycle always
        // knows whether someone is at the Mac when a rest is due.
        let tick = Timer(timeInterval: config.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick.tolerance = config.tickInterval / 4
        RunLoop.main.add(tick, forMode: .common)
        timers = [tick]
    }

    private func tick() {
        let now = clock()
        let idleNow = idle.idleSeconds()
        // If an "unlocked"/"screen saver stopped" notification was missed, don't stay
        // paused forever. Only after a while, though: the input that starts a hot-corner
        // screen saver must not cancel the pause it just began.
        if cycle.presenceAway {
            if awaySince == nil { awaySince = now }
            if let since = awaySince, now.timeIntervalSince(since) >= 15,
               idle.rawIdleSeconds() < SmartReset.activeIdle, Self.someoneIsAtTheScreen() {
                presence?.reset()
            }
        } else {
            awaySince = nil
        }
        var effects = cycle.handle(.idleSample(idleNow), at: now)
        effects += cycle.handle(.tick, at: now)
        effects.forEach(apply)
        render()
    }

    private func sampleIdle() {
        send(.idleSample(idle.idleSeconds()))
    }

    private func apply(_ effect: Effect) {
        let now = clock()
        switch effect {
        case .showHeadsUp:
            if let m = cycle.headsUp(at: now) { headsUp.show(m) }
        case .hideHeadsUp:
            headsUp.hide()
        case .showRest:
            NSApp.activate()
            if let m = cycle.restCard(at: now) { overlay.show(m) }
        case .hideRest:
            overlay.hide()
            if !settingsWindow.isVisible { NSApp.hide(nil) }
        case .lockFocus:
            // Presentation options only take effect while we are the active app.
            NSApp.activate()
            focus.lock()
        case .unlockFocus:
            focus.unlock()
        case .playChime(let c):
            chimesPlayed.append(c.rawValue)
            chimes.play(c)
        case .startChimeLoop:
            chimesPlayed.append("loop")
            chimes.startLoop()
        case .stopChime:
            chimes.stopLoop()
        case .runHook(let h):
            let path = h == .start ? cycle.settings.startHookPath : cycle.settings.endHookPath
            if let path, hooks.run(path: path, hook: h) { hooksRun.append("\(h.rawValue):\(path)") }
        }
    }

    private func render() {
        let now = clock()
        if let m = cycle.restCard(at: now) { overlay.update(m) }
        if let m = cycle.headsUp(at: now) { headsUp.update(m) }
        statusItem?.update(cycle: cycle, now: now)
    }

    static func sessionLocked() -> Bool {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (info?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Our session is the one on screen (not switched away from), unlocked, display awake,
    /// and no screen saver running.
    static func someoneIsAtTheScreen() -> Bool {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard (info?[kCGSessionOnConsoleKey] as? Bool) == true, !sessionLocked(),
              CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return false }
        return !NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" || $0.bundleIdentifier == "com.apple.ScreenSaver.Engine.legacyScreenSaver"
        }
    }

    // MARK: Commands

    func perform(_ target: ControlTarget) {
        switch target {
        case .menuRestNow, .headsUpRestNow: send(.restNow)
        case .menuPostpone: send(.snooze(5 * 60))
        case .menuRestart: send(.restartCountdown)
        case .menuToggle: send(.setEnabled(!cycle.settings.enabled)); persistCycleSettings()
        case .menuSettings: showSettings()
        case .menuQuit: NSApp.terminate(nil)
        case .headsUpSnooze: send(.snooze(5 * 60))
        case .cardSnooze, .cardSnooze5, .cardSnooze15, .cardFinish: break // handled by the card itself
        }
    }

    func run(_ command: ExternalCommand) {
        if let event = command.event(given: cycle) {
            send(event)
            if case .setEnabled = event { persistCycleSettings() }
        } else if command == .openSettings {
            showSettings()
        }
    }

    @discardableResult
    func handle(url: URL) -> Bool {
        guard let command = ExternalCommand(url: url) else { return false }
        run(command)
        return true
    }

    /// Settings edited in the Settings window (or by tests through the same path).
    func updateSettings(_ new: Settings) {
        let old = cycle.settings
        // The cycle has the last word (e.g. breaks cannot be switched off mid strict rest),
        // so clamp, hand over, then save what the cycle kept.
        send(.settingsChanged(new.clamped(to: store.limits)))
        let saved = store.save(cycle.settings)
        if saved.showInDock != old.showInDock || saved.showInMenuBar != old.showInMenuBar { applyAppearance(saved) }
        settingsModel.sync(saved)
        if saved.launchAtLogin != old.launchAtLogin { setLoginItem(saved.launchAtLogin) }
    }

    /// The cycle changed `enabled` itself (menu toggle, URL, script): save and reflect it.
    private func persistCycleSettings() {
        store.save(cycle.settings)
        settingsModel.sync(cycle.settings)
    }

    private func applyAppearance(_ s: Settings) {
        // While Settings is open the app keeps a Dock icon, or macOS may not let it take the focus.
        NSApp.setActivationPolicy(s.showInDock || settingsWindow.isVisible ? .regular : .accessory)
        statusItem?.isVisible = s.showInMenuBar
    }

    // MARK: Open at login
    // macOS owns the truth: the toggle follows SMAppService, never the other way round.

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
            settingsModel.loginItemMessage = nil
        } catch {
            let app = Bundle.main.bundleURL
            settingsModel.loginItemMessage = LoginItemProblem.message(
                for: error, appPath: app.path, appExists: FileManager.default.fileExists(atPath: app.path))
        }
        refreshLoginItem(keepMessage: true)
    }

    /// Reads the login item from macOS and makes the setting agree with it.
    func refreshLoginItem(keepMessage: Bool = false) {
        let state = loginItem.state
        settingsModel.loginItemState = state
        if !keepMessage, state != .disabled { settingsModel.loginItemMessage = nil }
        guard cycle.settings.launchAtLogin != state.isOn else { return }
        var s = cycle.settings
        s.launchAtLogin = state.isOn
        let saved = store.save(s)
        send(.settingsChanged(saved))
        settingsModel.sync(saved)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Softfocus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    /// Settings stays closed during a strict rest (⌘, still reaches us with the menu bar
    /// hidden), so the rest can't be shortened or made non-strict from there.
    func showSettings() {
        guard !cycle.focusLocked else { NSSound.beep(); return }
        settingsWindow.show()
    }

    // MARK: AppleScript properties (see Softfocus.sdef)

    public func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        ["breaksEnabled", "secondsUntilRest", "restPhase"].contains(key)
    }

    @objc public var breaksEnabled: Bool {
        get { cycle.settings.enabled }
        set { run(.setEnabled(newValue)) }
    }

    @objc public var secondsUntilRest: Double { cycle.secondsUntilRest(at: clock()) ?? -1 }

    @objc public var restPhase: String { cycle.phase.name }

    // MARK: Test-control channel

    private func startControlChannel() {
        guard let path = config.controlSocket else { return }
        let server = ControlServer(path: path) { request in
            await MainActor.run { AppCoordinator.shared?.handleControl(request) ?? .failure("app gone") }
        }
        do {
            try server.start()
            control = server
        } catch {
            log.error("control channel failed: \(String(describing: error))")
        }
    }

    func handleControl(_ r: ControlRequest) -> ControlResponse {
        var error: String?
        switch r.cmd {
        case .state, .ui:
            break
        case .press:
            guard let t = r.target.flatMap(ControlTarget.init(rawValue:)) else { return .failure("unknown target") }
            let pressed: Bool
            switch t {
            case .cardSnooze, .cardSnooze5, .cardSnooze15, .cardFinish:
                pressed = overlay.card?.press(t) ?? false
            case .headsUpSnooze, .headsUpRestNow:
                pressed = headsUp.press(t)
            case .menuQuit:
                // Answer first; termination would close the socket mid-reply.
                pressed = statusItem?.isEnabled(.menuQuit) ?? false
                if pressed { DispatchQueue.main.async { NSApp.terminate(nil) } }
            default:
                pressed = statusItem?.press(t) ?? false
            }
            if !pressed { error = "\(t.rawValue) is not available" }
        case .key:
            let key: RestKey = switch r.key {
            case "escape": .escape
            case "return": .returnKey
            case "space": .space
            default: .other
            }
            if !overlay.simulateKey(key, shift: r.shift ?? false) { error = "no rest card" }
        case .idle:
            idle.override = r.seconds
            sampleIdle()
        case .presence:
            send(.presence(away: r.away ?? false))
        case .settings:
            guard let s = r.settings else { return .failure("missing settings") }
            updateSettings(s)
        case .renderCard:
            guard let path = r.path, overlay.renderCard(to: path) else { return .failure("no rest card to render") }
        case .url:
            guard let s = r.path, let url = URL(string: s), handle(url: url) else { return .failure("bad url") }
        case .renderSettings:
            guard let path = r.path, settingsWindow.render(to: path) else { return .failure("settings not open") }
        case .appleScript:
            guard let source = r.path, let script = NSAppleScript(source: source) else { return .failure("no script") }
            var info: NSDictionary?
            let out = script.executeAndReturnError(&info)
            if let info {
                return .failure("AppleScript error \(info[NSAppleScript.errorNumber] ?? "?"): \(info[NSAppleScript.errorMessage] ?? "")")
            }
            scriptResult = out.stringValue ?? (out.descriptorType == typeTrue ? "true" : out.descriptorType == typeFalse ? "false" : nil)
        case .loginItem:
            guard let fake = loginItem as? FakeLoginItem,
                  let state = r.key.flatMap(LoginItemState.init(rawValue:)) else { return .failure("no fake login item") }
            fake.state = state // the app notices on its own (activation, Settings opening)
        }
        let now = clock()
        defer { scriptResult = nil }
        return ControlResponse(ok: error == nil, error: error, state: StateSnapshot(cycle: cycle, now: now),
                               ui: r.cmd == .ui ? uiSnapshot() : nil, result: scriptResult)
    }

    func uiSnapshot() -> UISnapshot {
        func rect(_ r: NSRect) -> Rect { Rect(x: r.minX, y: r.minY, width: r.width, height: r.height) }
        func snap(_ w: NSWindow) -> WindowSnapshot {
            WindowSnapshot(windowNumber: w.windowNumber, frame: rect(w.frame), level: w.level.rawValue,
                           alpha: w.alphaValue, visible: w.isVisible, isKey: w.isKeyWindow)
        }
        var card: CardSnapshot?
        if let panel = overlay.panel, let view = overlay.card {
            card = CardSnapshot(
                window: snap(panel), headline: view.headline.stringValue,
                elapsed: view.elapsed.stringValue, remaining: view.remaining.stringValue,
                progress: view.ring.progress,
                snoozeEnabled: view.snoozeButton.isEnabled, finishEnabled: view.finishButton.isEnabled,
                snoozeMenu: view.snoozeMenu.items.map(\.title))
        }
        statusItem?.rebuildMenu()
        return UISnapshot(
            screens: NSScreen.screens.map { rect($0.frame) },
            shields: overlay.shields.map(snap),
            card: card,
            headsUp: headsUp.panel.map(snap),
            headsUpText: headsUp.text,
            statusItemVisible: statusItem?.isVisible ?? false,
            menuItems: statusItem?.menuTitles ?? [],
            settingsWindowVisible: settingsWindow.isVisible,
            activationPolicy: NSApp.activationPolicy() == .regular ? "regular" : "accessory",
            presentationOptions: NSApp.presentationOptions.rawValue,
            hooksRun: hooksRun,
            chimesPlayed: chimesPlayed,
            loginItem: loginItem.state,
            loginItemMessage: settingsModel.loginItemMessage,
            loginItemSettingsOpened: (loginItem as? FakeLoginItem)?.settingsOpened ?? 0)
    }
}
