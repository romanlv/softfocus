import AppKit
import SoftfocusCore

/// Softfocus's visual language: a calm dark surface, one teal accent, green for "done".
enum Palette {
    static let accent = NSColor(srgbRed: 0.36, green: 0.84, blue: 0.77, alpha: 1)      // teal
    static let complete = NSColor(srgbRed: 0.42, green: 0.86, blue: 0.47, alpha: 1)    // green
    static let surfaceTop = NSColor(srgbRed: 0.135, green: 0.14, blue: 0.15, alpha: 0.97)
    static let surfaceBottom = NSColor(srgbRed: 0.095, green: 0.10, blue: 0.11, alpha: 0.97)
    static let hairline = NSColor(white: 1, alpha: 0.10)
    static let primaryText = NSColor(white: 1, alpha: 0.94)
    static let secondaryText = NSColor(white: 1, alpha: 0.58)
    static let tertiaryText = NSColor(white: 1, alpha: 0.38)
    static let track = NSColor(white: 1, alpha: 0.09)
    static let quietFill = NSColor(white: 1, alpha: 0.11)
    static let quietFillHover = NSColor(white: 1, alpha: 0.16)
    static let quietFillPressed = NSColor(white: 1, alpha: 0.07)
    static let shieldAlpha: CGFloat = 0.6
}

enum Typeface {
    /// SF Pro Rounded with fixed-width digits, so a ticking clock doesn't jitter.
    static func roundedDigits(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var d = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        d = d.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: d, size: size) ?? base
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    }
}

/// Window level of the dimming shields: above normal apps, full-screen apps and the menu bar.
let shieldLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
let cardLevel = NSWindow.Level.screenSaver

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: Surface

/// The card's body: a softly lit rounded surface with a hairline edge. Drawn (not a
/// visual-effect view) because it sits on a uniform dark scrim, where blur adds nothing,
/// and so it renders identically into bitmaps.
final class SurfaceView: NSView {
    var radius: CGFloat = 26 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        // A hairline edge that catches a little more light along the top.
        NSGraphicsContext.saveGraphicsState()
        let edge = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        edge.addClip()
        NSGradient(starting: NSColor(white: 1, alpha: 0.20), ending: NSColor(white: 1, alpha: 0.07))?
            .draw(in: NSRect(x: rect.minX, y: rect.maxY - radius * 2, width: rect.width, height: radius * 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
        NSGradient(starting: Palette.surfaceTop, ending: Palette.surfaceBottom)?.draw(in: body, angle: -90)
        Palette.hairline.withAlphaComponent(0.07).setStroke()
        edge.stroke()
    }
}

// MARK: Progress ring

/// A ring that fills clockwise from 12 o'clock, with the time left in the middle.
final class ProgressRing: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var complete = false { didSet { needsDisplay = true } }
    static let lineWidth: CGFloat = 9

    override var intrinsicContentSize: NSSize { NSSize(width: 156, height: 156) }

    override func draw(_ dirtyRect: NSRect) {
        let w = Self.lineWidth
        let r = min(bounds.width, bounds.height) / 2 - w / 2 - 6
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = w
        Palette.track.setStroke()
        track.stroke()

        let p = complete ? 1 : progress.clamped(to: 0...1)
        guard p > 0 else { return }
        let color = complete ? Palette.complete : Palette.accent
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
        arc.lineWidth = w
        arc.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()
        color.setStroke()
        arc.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: Buttons

/// Capsule button in the current macOS idiom: a filled primary, or a quiet secondary.
final class PillButton: NSButton {
    enum Style { case primary, secondary }
    struct Corners: OptionSet {
        let rawValue: Int
        static let leading = Corners(rawValue: 1)
        static let trailing = Corners(rawValue: 2)
        static let all: Corners = [.leading, .trailing]
    }

    var style: Style { didSet { needsDisplay = true } }
    var tint: NSColor = Palette.accent { didSet { needsDisplay = true } }
    var corners: Corners = .all { didSet { needsDisplay = true } }
    var symbol: String? { didSet { needsDisplay = true } }
    /// Hairline on the leading edge, for the chevron half of a split button.
    var leadingDivider = false { didSet { needsDisplay = true } }
    let height: CGFloat
    let fontSize: CGFloat
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, style: Style, height: CGFloat = 36, fontSize: CGFloat = 13) {
        self.style = style
        self.height = height
        self.fontSize = fontSize
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true // keys go to the panel, never to a focused button
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let w = symbol != nil && title.isEmpty ? height + 4 : label.size().width + height * 1.1
        return NSSize(width: w, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var textColor: NSColor {
        style == .primary && isEnabled ? NSColor(white: 0.06, alpha: 0.92) : Palette.primaryText
    }

    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: Typeface.rounded(fontSize, .semibold),
            .foregroundColor: textColor,
        ])
    }

    private func shape(_ rect: NSRect) -> NSBezierPath {
        let r = rect.height / 2
        let p = NSBezierPath()
        let l = corners.contains(.leading) ? r : 0, t = corners.contains(.trailing) ? r : 0
        p.move(to: NSPoint(x: rect.minX + l, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX - t, y: rect.minY))
        if t > 0 { p.appendArc(withCenter: NSPoint(x: rect.maxX - t, y: rect.midY), radius: t, startAngle: 270, endAngle: 90) }
        else { p.line(to: NSPoint(x: rect.maxX, y: rect.maxY)) }
        p.line(to: NSPoint(x: rect.minX + l, y: rect.maxY))
        if l > 0 { p.appendArc(withCenter: NSPoint(x: rect.minX + l, y: rect.midY), radius: l, startAngle: 90, endAngle: 270) }
        else { p.line(to: NSPoint(x: rect.minX, y: rect.minY)) }
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted || (cell?.isHighlighted ?? false)
        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        defer { ctx?.restoreGraphicsState() }
        ctx?.cgContext.setAlpha(isEnabled ? 1 : 0.35)

        let path = shape(bounds)
        switch isEnabled ? style : .secondary { // a disabled primary goes quiet, not muddy
        case .primary:
            var fill = tint
            if pressed { fill = tint.blended(withFraction: 0.18, of: .black) ?? tint }
            else if hovering && isEnabled { fill = tint.blended(withFraction: 0.12, of: .white) ?? tint }
            NSGradient(starting: fill.blended(withFraction: 0.10, of: .white) ?? fill, ending: fill)?.draw(in: path, angle: -90)
        case .secondary:
            (pressed ? Palette.quietFillPressed : hovering && isEnabled ? Palette.quietFillHover : Palette.quietFill).setFill()
            path.fill()
        }

        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: fontSize - 1, weight: .bold)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                self.textColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let x = title.isEmpty ? bounds.midX - img.size.width / 2 : bounds.minX + height * 0.45
            tinted.draw(in: NSRect(x: x, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                        from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35)
        }
        if leadingDivider {
            NSColor(white: 1, alpha: 0.12).setFill()
            NSRect(x: bounds.minX, y: bounds.minY + 9, width: 1, height: bounds.height - 18).fill()
        }
        if !title.isEmpty {
            let l = label, size = l.size()
            l.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}

/// Secondary capsule with an attached chevron that opens a menu of longer snoozes.
@MainActor
final class SplitPillButton: NSView {
    let main: PillButton
    let arrow: PillButton
    let choices: NSMenu

    var isEnabled = true {
        didSet { main.isEnabled = isEnabled; arrow.isEnabled = isEnabled }
    }

    init(title: String, menu: NSMenu) {
        main = PillButton(title: title, style: .secondary)
        arrow = PillButton(title: "", style: .secondary)
        choices = menu
        super.init(frame: .zero)
        main.corners = .leading
        arrow.corners = .trailing
        arrow.symbol = "chevron.down"
        arrow.leadingDivider = true
        arrow.target = self
        arrow.action = #selector(openMenu)
        arrow.setAccessibilityLabel("More snooze options")
        translatesAutoresizingMaskIntoConstraints = false
        for v in [main, arrow] { addSubview(v) }
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor),
            main.topAnchor.constraint(equalTo: topAnchor),
            main.bottomAnchor.constraint(equalTo: bottomAnchor),
            arrow.leadingAnchor.constraint(equalTo: main.trailingAnchor),
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor),
            arrow.topAnchor.constraint(equalTo: topAnchor),
            arrow.bottomAnchor.constraint(equalTo: bottomAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 38),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func openMenu() {
        choices.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
    }
}

/// A small keycap ("esc", "↩") followed by what it does.
final class KeyHintView: NSStackView {
    init(_ pairs: [(key: String, action: String)]) {
        super.init(frame: .zero)
        spacing = 14
        for (key, action) in pairs {
            let cap = Keycap(key)
            let text = NSTextField(labelWithString: action)
            text.font = .systemFont(ofSize: 11, weight: .regular)
            text.textColor = Palette.tertiaryText
            let pair = NSStackView(views: [cap, text])
            pair.spacing = 5
            addArrangedSubview(pair)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    final class Keycap: NSView {
        let text: String
        init(_ text: String) { self.text = text; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        private var attributed: NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                          .foregroundColor: Palette.secondaryText])
        }
        override var intrinsicContentSize: NSSize { NSSize(width: max(20, attributed.size().width + 10), height: 17) }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            let p = NSBezierPath(roundedRect: r, xRadius: 4.5, yRadius: 4.5)
            NSColor(white: 1, alpha: 0.07).setFill(); p.fill()
            NSColor(white: 1, alpha: 0.16).setStroke(); p.lineWidth = 1; p.stroke()
            let s = attributed.size()
            attributed.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
        }
    }
}

// MARK: Rest card

/// The rest card: an eye glyph, headline and a line of guidance; a progress ring with the
/// time left inside; Snooze (quiet, with longer choices) and Finish (primary); key hints.
@MainActor
final class RestCardView: NSView {
    let glyph = NSImageView()
    let headline = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let ring = ProgressRing()
    let remaining = NSTextField(labelWithString: "00:00")
    let elapsed = NSTextField(labelWithString: "00:00")
    private let elapsedLine = NSTextField(labelWithString: "")
    private let doneMark = NSImageView()
    let snoozeMenu = NSMenu()
    let snoozeButton: SplitPillButton
    let finishButton = PillButton(title: "Finish", style: .primary)
    private let hints = KeyHintView([("esc", "Snooze"), ("↩", "Finish")])
    private let strictNote = NSTextField(labelWithString: "")
    private let surface = SurfaceView()

    var onSnooze: ((TimeInterval) -> Void)?
    var onFinish: (() -> Void)?

    static let width: CGFloat = 380

    init() {
        snoozeButton = SplitPillButton(title: "Snooze 1 min", menu: snoozeMenu)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 380))
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        glyph.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        glyph.contentTintColor = Palette.accent

        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        headline.textColor = Palette.primaryText
        headline.alignment = .center
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Palette.secondaryText
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byTruncatingTail

        remaining.font = Typeface.roundedDigits(38, .semibold)
        remaining.textColor = Palette.primaryText
        remaining.alignment = .center
        remaining.setAccessibilityLabel("Time left")
        elapsed.isHidden = true // kept for scripting/tests; shown through `elapsedLine`
        elapsed.setAccessibilityLabel("Time rested")
        elapsedLine.font = Typeface.roundedDigits(12, .medium)
        elapsedLine.textColor = Palette.tertiaryText
        elapsedLine.alignment = .center
        doneMark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Rest complete")?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .bold))
        doneMark.contentTintColor = Palette.complete
        doneMark.isHidden = true
        doneMark.translatesAutoresizingMaskIntoConstraints = false
        doneMark.widthAnchor.constraint(equalToConstant: 46).isActive = true
        doneMark.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let center = NSStackView(views: [remaining, doneMark, elapsedLine])
        center.orientation = .vertical
        center.spacing = 2
        center.translatesAutoresizingMaskIntoConstraints = false
        ring.addSubview(center)
        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: ring.centerYAnchor, constant: 1),
            ring.widthAnchor.constraint(equalToConstant: 156),
            ring.heightAnchor.constraint(equalToConstant: 156),
        ])

        for (seconds, id) in zip(SnoozeChoice.seconds, [ControlTarget.cardSnooze, .cardSnooze5, .cardSnooze15]) {
            let item = NSMenuItem(title: "Snooze \(TimeText.durationLabel(seconds))", action: #selector(snoozeItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(seconds)
            item.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            snoozeMenu.addItem(item)
        }
        snoozeMenu.autoenablesItems = false
        snoozeButton.main.target = self
        snoozeButton.main.action = #selector(snoozeMain)
        snoozeButton.main.setAccessibilityIdentifier(ControlTarget.cardSnooze.rawValue)
        snoozeButton.main.toolTip = "Esc: 1 minute, Shift-Esc: 5 minutes"
        snoozeButton.arrow.setAccessibilityIdentifier("card.snooze.more")
        finishButton.target = self
        finishButton.action = #selector(finish)
        finishButton.setAccessibilityIdentifier(ControlTarget.cardFinish.rawValue)
        finishButton.toolTip = "Return or Space"

        let buttons = NSStackView(views: [snoozeButton, finishButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        strictNote.font = .systemFont(ofSize: 11)
        strictNote.textColor = Palette.tertiaryText
        strictNote.alignment = .center

        let column = NSStackView(views: [glyph, headline, subtitle, ring, buttons, hints, strictNote, elapsed])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 4
        column.setCustomSpacing(10, after: glyph)
        column.setCustomSpacing(18, after: subtitle)
        column.setCustomSpacing(22, after: ring)
        column.setCustomSpacing(14, after: buttons)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        headline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: column.widthAnchor),
            headline.widthAnchor.constraint(equalTo: column.widthAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    func render(_ model: RestCardModel) {
        let strictLocked = !model.canSnooze && !model.canFinish
        headline.stringValue = model.headline
        subtitle.stringValue = model.isComplete
            ? "Nicely done. Back to work when you're ready."
            : "Look far away and let your eyes relax."
        glyph.contentTintColor = model.isComplete ? Palette.complete : Palette.accent
        elapsed.stringValue = model.elapsed
        remaining.stringValue = model.remaining
        remaining.isHidden = model.isComplete
        doneMark.isHidden = !model.isComplete
        elapsedLine.stringValue = "\(model.elapsed) rested"
        ring.progress = model.progress
        ring.complete = model.isComplete
        snoozeButton.isEnabled = model.canSnooze
        snoozeMenu.items.forEach { $0.isEnabled = model.canSnooze }
        finishButton.isEnabled = model.canFinish
        finishButton.title = model.isComplete ? "Back to Work" : "Finish"
        finishButton.tint = model.isComplete ? Palette.complete : Palette.accent
        hints.isHidden = strictLocked
        strictNote.isHidden = !strictLocked
        strictNote.stringValue = "Strict rest · you can finish when the time is up"
        setAccessibilityLabel(model.isComplete ? "Rest complete" : "Rest, \(model.elapsed) rested, \(model.remaining) left")
    }

    @objc private func snoozeMain() { onSnooze?(SnoozeChoice.seconds[0]) }
    @objc private func snoozeItem(_ sender: NSMenuItem) { onSnooze?(TimeInterval(sender.tag)) }
    @objc private func finish() { onFinish?() }

    /// Presses a control the way a click would: disabled controls do nothing.
    func press(_ target: ControlTarget) -> Bool {
        switch target {
        case .cardSnooze:
            guard snoozeButton.isEnabled else { return false }
            snoozeButton.main.performClick(nil)
            return true
        case .cardSnooze5, .cardSnooze15:
            guard let i = snoozeMenu.items.firstIndex(where: { $0.identifier?.rawValue == target.rawValue }),
                  snoozeButton.isEnabled, snoozeMenu.items[i].isEnabled else { return false }
            snoozeMenu.performActionForItem(at: i)
            return true
        case .cardFinish:
            guard finishButton.isEnabled else { return false }
            finishButton.performClick(nil)
            return true
        default:
            return false
        }
    }
}

// MARK: Windows

/// Borderless panel that can take keyboard focus and routes every key press to `onKey`.
final class RestCardPanel: NSPanel {
    var onKey: ((RestKey, Bool) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let key: RestKey = switch event.keyCode {
            case 53: .escape
            case 36, 76: .returnKey
            case 49: .space
            default: .other
            }
            onKey?(key, event.modifierFlags.contains(.shift))
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
func makeOverlayWindow<W: NSWindow>(_ type: W.Type, frame: NSRect, level: NSWindow.Level,
                                    style: NSWindow.StyleMask = [.borderless]) -> W {
    let w = W(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
    w.level = level
    w.isReleasedWhenClosed = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    w.isOpaque = false
    w.hasShadow = false
    w.animationBehavior = .none
    return w
}

/// Owns the dimming shields (one per display) and the rest card.
@MainActor
public final class RestOverlayController {
    private(set) var shields: [NSWindow] = []
    private(set) var panel: RestCardPanel?
    private(set) var card: RestCardView?
    private(set) var shownAt: Date?
    private var screenObserver: NSObjectProtocol?

    var onSnooze: ((TimeInterval) -> Void)?
    var onFinish: (() -> Void)?
    var onKey: ((RestKey, Bool, TimeInterval) -> Void)?

    public init() {}

    public var isVisible: Bool { panel != nil }

    func show(_ model: RestCardModel) {
        guard panel == nil else { update(model); return }
        shownAt = Date()
        buildShields()

        let card = RestCardView()
        card.onSnooze = { [weak self] in self?.onSnooze?($0) }
        card.onFinish = { [weak self] in self?.onFinish?() }
        card.render(model)
        card.layoutSubtreeIfNeeded()
        let size = card.fittingSize

        let frame = Self.cardFrame(size: size, on: NSScreen.main ?? NSScreen.screens.first)
        // Non-activating: the card can take key focus even when macOS declines to bring
        // a background app forward.
        let panel = makeOverlayWindow(RestCardPanel.self, frame: frame, level: cardLevel,
                                      style: [.borderless, .nonactivatingPanel])
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = card
        panel.setAccessibilityIdentifier("rest.card")
        panel.onKey = { [weak self] key, shift in
            guard let self, let shownAt = self.shownAt else { return }
            self.onKey?(key, shift, Date().timeIntervalSince(shownAt))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        self.card = card

        let shields = self.shields
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
            for s in shields { s.animator().alphaValue = Palette.shieldAlpha }
        }, completionHandler: {
            // Pin the final values in case the animation was skipped.
            MainActor.assumeIsolated {
                panel.alphaValue = 1
                for s in shields { s.alphaValue = Palette.shieldAlpha }
            }
        })

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.buildShields(animated: false)
                self?.centerCard()
            }
        }
    }

    func update(_ model: RestCardModel) {
        card?.render(model)
    }

    /// Centre of the main display, a little above the middle.
    static func cardFrame(size: NSSize, on screen: NSScreen?) -> NSRect {
        let sf = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2 + sf.height * 0.08,
                      width: size.width, height: size.height)
    }

    /// Keeps the card on a display that exists (after one is unplugged or rearranged).
    func centerCard() {
        guard let panel else { return }
        panel.setFrame(Self.cardFrame(size: panel.frame.size, on: NSScreen.main ?? NSScreen.screens.first), display: true)
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for s in shields { s.orderOut(nil) }
        shields.removeAll()
        panel?.orderOut(nil)
        panel = nil
        card = nil
        shownAt = nil
    }

    private func buildShields(animated: Bool = true) {
        for s in shields { s.orderOut(nil) }
        shields = NSScreen.screens.map { screen in
            let w = makeOverlayWindow(NSWindow.self, frame: screen.frame, level: shieldLevel)
            w.backgroundColor = .black
            w.alphaValue = animated ? 0 : Palette.shieldAlpha
            w.setAccessibilityIdentifier("rest.shield")
            w.orderFrontRegardless()
            return w
        }
        panel?.orderFrontRegardless()
    }

    /// Sends a synthetic key press through the panel's normal event path.
    func simulateKey(_ key: RestKey, shift: Bool) -> Bool {
        guard let panel else { return false }
        let (code, chars): (UInt16, String) = switch key {
        case .escape: (53, "\u{1b}")
        case .returnKey: (36, "\r")
        case .space: (49, " ")
        case .other: (0, "a")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
        ) else { return false }
        panel.sendEvent(event)
        return true
    }

    /// Writes the card as a PNG. Used by tests and for docs; needs no screen-recording permission.
    func renderCard(to path: String) -> Bool {
        guard let card, let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return false }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
