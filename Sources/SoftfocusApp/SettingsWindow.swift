import AppKit
import Observation
import SoftfocusCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class SettingsModel {
    public var settings: SoftfocusCore.Settings {
        didSet { if settings != oldValue && !syncing { onChange?(settings) } }
    }
    public var loginItemState: LoginItemState = .disabled
    /// Allowed ranges (the store's; tests allow shorter values).
    public var limits: SettingsLimits = .standard
    public var loginItemMessage: String?
    @ObservationIgnored var onChange: ((SoftfocusCore.Settings) -> Void)?
    @ObservationIgnored var onOpenLoginItems: (() -> Void)?
    @ObservationIgnored private var syncing = false

    public init(settings: SoftfocusCore.Settings) { self.settings = settings }

    /// Updates from the app side without echoing a change back.
    func sync(_ s: SoftfocusCore.Settings) {
        syncing = true
        settings = s
        syncing = false
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "General", rest = "Rest", scripts = "Scripts"

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .rest: "eye"
        case .scripts: "terminal"
        }
    }
}

/// Fixed width for every pane; height follows the content.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A toggle with a second, smaller line explaining it.
private struct DetailToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let id: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text(detail)
        }
        .accessibilityIdentifier(id)
    }
}

private struct Caption: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) { self.text = text; self.color = color }
    var body: some View { Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true) }
}

struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Pane { Form {
            Section {
                Toggle("Remind me to take breaks", isOn: $model.settings.enabled)
                    .accessibilityIdentifier(SettingsID.enabled)
                LabeledContent("Rest every") {
                    DurationInput(seconds: $model.settings.workSeconds, field: .work(model.limits),
                                  name: "Rest every", id: SettingsID.workInterval)
                }
                LabeledContent("Rest for") {
                    DurationInput(seconds: $model.settings.restSeconds, field: .rest(model.limits),
                                  name: "Rest for", id: SettingsID.restLength)
                }
                Toggle("Warn 10 seconds before a rest", isOn: Binding(
                    get: { model.settings.headsUpSeconds > 0 },
                    set: { model.settings.headsUpSeconds = $0 ? 10 : 0 }))
                    .accessibilityIdentifier(SettingsID.headsUp)
            }

            Section {
                Toggle("Open at login", isOn: $model.settings.launchAtLogin)
                    .accessibilityIdentifier(SettingsID.launchAtLogin)
                if model.loginItemState == .requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Caption("macOS needs your OK: turn Softfocus on in System Settings › General › Login Items.",
                                color: .orange)
                            .accessibilityIdentifier(SettingsID.loginItemNote)
                        Spacer()
                        Button("Open Login Items…") { model.onOpenLoginItems?() }
                            .accessibilityIdentifier(SettingsID.openLoginItems)
                    }
                }
                if let message = model.loginItemMessage {
                    Caption(message, color: .red).accessibilityIdentifier(SettingsID.loginItemNote)
                }
                Toggle("Show in menu bar", isOn: $model.settings.showInMenuBar)
                    .accessibilityIdentifier(SettingsID.menuBar)
                Toggle("Show in Dock", isOn: $model.settings.showInDock)
                    .accessibilityIdentifier(SettingsID.dock)
                if model.settings.isHeadless {
                    Caption("Softfocus will keep running with no icon. Open it again from Finder to get back here.",
                            color: .orange)
                        .accessibilityIdentifier(SettingsID.headlessNote)
                }
            }
        } }
    }
}

/// Exact type-in duration: number field, stepper, unit menu, and one-click presets.
struct DurationInput: View {
    @Binding var seconds: TimeInterval
    let field: DurationField
    let name: String
    let id: String
    /// Unit the user picked; nil means "whatever shows the value best".
    @State private var chosenUnit: DurationUnit?
    /// What is in the text field while the user types.
    @State private var draft = ""
    /// Shown when a typed value had to be brought into range.
    @State private var rangeNote: String?
    @FocusState private var editing: Bool

    private var unit: DurationUnit { chosenUnit ?? field.unit(for: seconds) }
    private var shown: String { String(field.amount(seconds, in: unit)) }

    /// Applies the typed text: exact when valid; rounded or clamped with a note when not.
    private func commit() {
        guard draft != shown else { return }
        let parsed = field.parse(draft, unit: unit)
        rangeNote = parsed.note
        if let value = parsed.seconds {
            // A value the chosen unit can't show exactly (1.5 min) switches to the automatic unit.
            if let u = chosenUnit, value.truncatingRemainder(dividingBy: u.factor) != 0 { chosenUnit = nil }
            seconds = value
        }
        draft = shown
    }

    /// Commits half-typed text before another control acts on the value.
    private func commitPending() { if draft != shown { commit() } }

    /// Stepper and presets: the field always shows the new value, even while focused.
    private func set(_ value: TimeInterval, resetUnit: Bool = false) {
        rangeNote = nil
        if resetUnit { chosenUnit = nil }
        seconds = value
        draft = shown
    }

    private var unitChoice: Binding<DurationUnit> {
        Binding(get: { unit }, set: { new in
            commitPending()
            let old = unit
            chosenUnit = new
            seconds = field.changingUnit(seconds, from: old, to: new)
        })
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                TextField(name, text: $draft)
                    .focused($editing)
                    .onSubmit(commit)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 60)
                    .accessibilityIdentifier(id + ".field")
                    .help("Type any value from \(field.rangeText)")
                Stepper(name, onIncrement: { commitPending(); set(field.stepped(seconds, unit: unit, up: true)) },
                        onDecrement: { commitPending(); set(field.stepped(seconds, unit: unit, up: false)) })
                    .labelsHidden()
                    .accessibilityIdentifier(id + ".stepper")
                if field.units.count > 1 {
                    Picker(name, selection: unitChoice) {
                        ForEach(field.units, id: \.self) { Text($0.shortLabel).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier(id + ".unit")
                } else {
                    Text(unit.shortLabel).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(field.presets, id: \.self) { preset in
                    let selected = preset == seconds
                    Button(field.label(preset)) { set(field.clamp(preset), resetUnit: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .fontWeight(selected ? .semibold : .regular)
                    .accessibilityIdentifier("\(id).preset.\(Int(preset))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if let rangeNote {
                Text(rangeNote).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier(id + ".note")
            }
        }
        .onAppear { draft = shown }
        .onDisappear { commitPending() } // closing the window or switching tabs keeps what was typed
        .onChange(of: editing) { _, now in if !now { commit() } }
        .onChange(of: seconds) { _, new in
            // Typing never changes `seconds` until commit, so any change here came from
            // elsewhere (stepper, preset, another window): always show it.
            if let u = chosenUnit, new.truncatingRemainder(dividingBy: u.factor) != 0 { chosenUnit = nil }
            draft = shown
        }
        .onChange(of: unit) { _, _ in draft = shown }
    }
}

struct RestPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Pane { Form {
            Section {
                DetailToggle(title: "Strict: no snoozing or finishing early",
                             detail: "Hides the Dock and menu bar and blocks app switching until the rest is over.",
                             isOn: $model.settings.strictMode, id: SettingsID.strict)
                DetailToggle(title: "Close the rest card when time is up",
                             detail: "Otherwise a chime repeats until you press Finish.",
                             isOn: $model.settings.autoFinish, id: SettingsID.autoFinish)
                Toggle("Play sounds", isOn: $model.settings.soundsOn)
                    .accessibilityIdentifier(SettingsID.sounds)
            }
            Section {
                DetailToggle(title: "Count time away from the Mac as a rest",
                             detail: "After a long idle stretch, sleep, lock or screen saver, the countdown starts over.",
                             isOn: $model.settings.smartReset, id: SettingsID.smartReset)
            }
        } }
    }
}

struct ScriptsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Pane { Form {
            Section {
                HookRow(title: "When a rest starts", hook: .start, path: $model.settings.startHookPath)
                HookRow(title: "When a rest ends", hook: .end, path: $model.settings.endHookPath)
            } footer: {
                Caption("Shell scripts get “start” or “end” as their first argument and in SOFTFOCUS_HOOK. "
                        + "AppleScripts and Automator workflows run as they are.")
            }
        } }
    }
}

struct HookRow: View {
    let title: String
    let hook: Hook
    @Binding var path: String?
    @State private var choosing = false

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.shellScript, .unixExecutable, .appleScript, .osaScript, .script]
        for ext in ["workflow", "scptd", "command", "sh", "zsh"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Nothing")
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(path ?? "")
                    .accessibilityIdentifier(SettingsID.hook(hook, "path"))
                Button("Choose…") { choosing = true }
                    .accessibilityIdentifier(SettingsID.hook(hook, "choose"))
                if path != nil {
                    Button("Clear") { path = nil }
                        .accessibilityIdentifier(SettingsID.hook(hook, "clear"))
                }
            }
        }
        // A sheet on the Settings window: the app keeps running (timers, rests) meanwhile.
        .fileImporter(isPresented: $choosing, allowedContentTypes: Self.allowedTypes) { result in
            if case .success(let url) = result { path = url.path }
        }
        .fileDialogMessage("Choose a shell script, AppleScript or Automator workflow.")
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    var isVisible: Bool { window?.isVisible ?? false }
    var onShow: (() -> Void)?

    func show() {
        onShow?()
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.allowUserInteraction]
            for tab in SettingsTab.allCases {
                let host: NSViewController = switch tab {
                case .general: NSHostingController(rootView: GeneralPane(model: model))
                case .rest: NSHostingController(rootView: RestPane(model: model))
                case .scripts: NSHostingController(rootView: ScriptsPane(model: model))
                }
                (host as? NSHostingController<GeneralPane>)?.sizingOptions = .preferredContentSize
                (host as? NSHostingController<RestPane>)?.sizingOptions = .preferredContentSize
                (host as? NSHostingController<ScriptsPane>)?.sizingOptions = .preferredContentSize
                host.title = tab.rawValue
                let item = NSTabViewItem(viewController: host)
                item.label = tab.rawValue
                item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.rawValue)
                item.identifier = tab.rawValue
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.setAccessibilityIdentifier(SettingsID.window)
            w.center()
            // Ending editing on close commits half-typed values (the field commits on focus loss).
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { _ = w.makeFirstResponder(nil) }
            }
            window = w
            self.tabs = tabs
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.windowNumber }

    func close() { window?.orderOut(nil) }

    /// Writes the window's content as a PNG (for docs and visual review).
    func render(to path: String) -> Bool {
        // The frame view includes the title bar and toolbar tabs.
        guard let view = window?.contentView?.superview ?? window?.contentView, isVisible,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
