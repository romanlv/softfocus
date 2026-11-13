import AppKit
import SoftfocusCore

// MARK: Heads-up panel

/// Content of the heads-up panel: a compact pill in the card's style.
@MainActor
final class HeadsUpView: NSView {
    let label = NSTextField(labelWithString: "")
    let snooze = PillButton(title: "Snooze 5 min", style: .secondary, height: 28, fontSize: 12)
    let restNow = PillButton(title: "Rest Now", style: .primary, height: 28, fontSize: 12)

    init() {
        super.init(frame: .zero)
        let bg = SurfaceView()
        bg.radius = 22
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)
        let icon = NSImageView(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = Palette.accent
        label.font = Typeface.roundedDigits(14, .semibold)
        label.textColor = Palette.primaryText
        snooze.setAccessibilityIdentifier(ControlTarget.headsUpSnooze.rawValue)
        restNow.setAccessibilityIdentifier(ControlTarget.headsUpRestNow.rawValue)
        let stack = NSStackView(views: [icon, label, snooze, restNow])
        stack.spacing = 8
        stack.setCustomSpacing(18, after: label)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor), bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor), bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(_ model: HeadsUpModel) { label.stringValue = "Rest in \(model.countdown)" }
}

/// Small floating panel shown a few seconds before a rest, top-right of the main display.
@MainActor
public final class HeadsUpController {
    private(set) var panel: NSPanel?
    private var view: HeadsUpView?

    var onSnooze: (() -> Void)?
    var onRestNow: (() -> Void)?

    public init() {}

    var text: String? { view?.label.stringValue }

    func show(_ model: HeadsUpModel) {
        if let view { view.render(model); return }
        let v = HeadsUpView()
        v.snooze.target = self; v.snooze.action = #selector(snoozeTapped)
        v.restNow.target = self; v.restNow.action = #selector(restNowTapped)
        v.render(model)
        v.layoutSubtreeIfNeeded()
        let size = v.fittingSize
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let frame = NSRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12, width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = v
        p.setAccessibilityIdentifier("headsup")
        p.orderFrontRegardless()
        panel = p
        view = v
    }

    func update(_ model: HeadsUpModel) { view?.render(model) }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    func press(_ target: ControlTarget) -> Bool {
        guard let view else { return false }
        switch target {
        case .headsUpSnooze: view.snooze.performClick(nil)
        case .headsUpRestNow: view.restNow.performClick(nil)
        default: return false
        }
        return true
    }

    @objc private func snoozeTapped() { onSnooze?() }
    @objc private func restNowTapped() { onRestNow?() }
}

// MARK: Menu bar icon

public enum IconMode: Equatable, Sendable { case off, working, resting, away }

public enum IconRenderer {
    /// 18 pt template image: a ring that fills clockwise as the work period runs out,
    /// solid while resting, slashed when off, dashed while away.
    @MainActor
    public static func image(mode: IconMode, progress: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 7
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ring.lineWidth = 1.5
            NSColor.black.set()
            switch mode {
            case .off:
                ring.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: c.x - r + 1, y: c.y - r + 1))
                slash.line(to: NSPoint(x: c.x + r - 1, y: c.y + r - 1))
                slash.lineWidth = 1.5
                slash.stroke()
            case .away:
                ring.setLineDash([2, 2], count: 2, phase: 0)
                ring.stroke()
            case .resting:
                ring.fill()
            case .working:
                ring.stroke()
                let p = max(0, min(1, progress))
                if p > 0 {
                    let wedge = NSBezierPath()
                    wedge.move(to: c)
                    wedge.appendArc(withCenter: c, radius: r - 2.5, startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
                    wedge.close()
                    wedge.fill()
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Softfocus"
        return img
    }
}

// MARK: Status item and menu

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var lastIconKey: String = ""

    /// Supplies the current cycle and time when the menu opens.
    var snapshot: (() -> (Cycle, Date))?
    var onAction: ((ControlTarget) -> Void)?

    public override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.setAccessibilityIdentifier("statusItem")
        item.button?.toolTip = "Softfocus"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuildMenu()
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    var menuTitles: [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    func update(cycle: Cycle, now: Date) {
        let mode: IconMode = switch cycle.phase {
        case .off: .off
        case .working: .working
        case .resting, .restDone: .resting
        case .away: .away
        }
        let progress = cycle.workProgress(at: now) ?? 0
        let key = "\(mode)-\(Int(progress * 24))"
        guard key != lastIconKey else { return }
        lastIconKey = key
        item.button?.image = IconRenderer.image(mode: mode, progress: progress)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func add(_ title: String, _ target: ControlTarget?, enabled: Bool = true, state: Bool? = nil, key: String = "") {
        let mi = NSMenuItem(title: title, action: target == nil ? nil : #selector(itemChosen(_:)), keyEquivalent: key)
        mi.target = self
        mi.isEnabled = enabled && target != nil
        if let target { mi.identifier = NSUserInterfaceItemIdentifier(target.rawValue) }
        if let state { mi.state = state ? .on : .off }
        menu.addItem(mi)
    }

    func rebuildMenu() {
        menu.removeAllItems()
        guard let (cycle, now) = snapshot?() else { return }
        add(cycle.statusLine(at: now), nil, enabled: false)
        menu.addItem(.separator())
        add("Rest Now", .menuRestNow, enabled: cycle.canRestNow)
        let working = cycle.secondsUntilRest(at: now) != nil
        add("Postpone 5 Minutes", .menuPostpone, enabled: working)
        add("Restart Countdown", .menuRestart, enabled: working)
        menu.addItem(.separator())
        add("Breaks Enabled", .menuToggle, enabled: !cycle.focusLocked, state: cycle.settings.enabled)
        menu.addItem(.separator())
        add("Settings…", .menuSettings, key: ",")
        add("Quit Softfocus", .menuQuit, enabled: cycle.canQuit, key: "q")
    }

    /// Chooses a menu item the way a click would. Disabled items do nothing.
    func press(_ target: ControlTarget) -> Bool {
        rebuildMenu()
        guard let i = menu.items.firstIndex(where: { $0.identifier?.rawValue == target.rawValue }),
              menu.items[i].isEnabled else { return false }
        menu.performActionForItem(at: i)
        return true
    }

    func isEnabled(_ target: ControlTarget) -> Bool {
        rebuildMenu()
        return menu.items.first { $0.identifier?.rawValue == target.rawValue }?.isEnabled ?? false
    }

    @objc private func itemChosen(_ sender: NSMenuItem) {
        guard let raw = sender.identifier?.rawValue, let t = ControlTarget(rawValue: raw) else { return }
        onAction?(t)
    }
}
