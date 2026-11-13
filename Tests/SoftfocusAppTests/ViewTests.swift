import AppKit
import Testing
@testable import SoftfocusApp
@testable import SoftfocusCore

/// In-process checks of the AppKit views, without launching the app.
@MainActor
@Suite("Views")
struct ViewTests {
    /// Controls dispatch their actions through NSApp, so it must exist (an app has one;
    /// a test process only if something created it).
    init() { _ = NSApplication.shared }

    func model(complete: Bool = false, strict: Bool = false) -> RestCardModel {
        RestCardModel(elapsed: complete ? "02:00" : "00:12", remaining: complete ? "00:00" : "01:48",
                      progress: complete ? 1 : 0.1, isComplete: complete,
                      canSnooze: !strict, canFinish: complete || !strict,
                      headline: complete ? "Rest complete" : "Time to rest your eyes")
    }

    @Test func cardShowsModel() {
        let card = RestCardView()
        card.render(model())
        #expect(card.headline.stringValue == "Time to rest your eyes")
        #expect(card.elapsed.stringValue == "00:12" && card.remaining.stringValue == "01:48")
        #expect(card.ring.progress == 0.1 && !card.ring.complete)
        #expect(card.snoozeMenu.items.map(\.title) == ["Snooze 1 minute", "Snooze 5 minutes", "Snooze 15 minutes"])
    }

    @Test func strictCardDisablesButtonsAndPressesDoNothing() {
        let card = RestCardView()
        var snoozed: TimeInterval?, finished = false
        card.onSnooze = { snoozed = $0 }
        card.onFinish = { finished = true }
        card.render(model(strict: true))
        #expect(!card.snoozeButton.isEnabled && !card.finishButton.isEnabled)
        #expect(!card.press(.cardSnooze) && !card.press(.cardSnooze15) && !card.press(.cardFinish))
        #expect(snoozed == nil && !finished)
    }

    @Test func pressesReachCallbacks() {
        let card = RestCardView()
        var snoozed: [TimeInterval] = [], finished = 0
        card.onSnooze = { snoozed.append($0) }
        card.onFinish = { finished += 1 }
        card.render(model())
        #expect(card.press(.cardSnooze) && card.press(.cardSnooze5) && card.press(.cardSnooze15))
        #expect(card.press(.cardFinish))
        #expect(snoozed == [60, 300, 900] && finished == 1, "snoozed \(snoozed) finished \(finished)")
        #expect(!card.press(.menuQuit))
    }

    @Test func cardLaysOutAtFixedWidth() {
        let card = RestCardView()
        card.render(model())
        card.layoutSubtreeIfNeeded()
        #expect(card.fittingSize.width == RestCardView.width)
        #expect(card.fittingSize.height > 300 && card.fittingSize.height < 420)
    }

    @Test(arguments: [IconMode.off, .working, .resting, .away])
    func menuBarIconIsTemplate(_ mode: IconMode) {
        let img = IconRenderer.image(mode: mode, progress: 0.4)
        #expect(img.isTemplate)
        #expect(img.size == NSSize(width: 18, height: 18))
        #expect(img.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
}

/// Renders previews of the card to build/previews/ for visual review.
@MainActor
@Suite("Previews")
struct PreviewTests {
    static var dir: URL {
        let d = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/previews")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func png(_ view: NSView, scale: CGFloat = 2) -> Data? {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.appearance = NSAppearance(named: .darkAqua)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @Test(arguments: [("card-resting", false, false), ("card-complete", true, false), ("card-strict", false, true)])
    func card(_ name: String, _ complete: Bool, _ strict: Bool) throws {
        let card = RestCardView()
        card.render(ViewTests().model(complete: complete, strict: strict))
        let data = try #require(png(card))
        try data.write(to: Self.dir.appendingPathComponent("\(name).png"))
        #expect(data.count > 5000)
    }
}

extension PreviewTests {
    @Test func headsUp() throws {
        let v = HeadsUpView()
        v.render(HeadsUpModel(countdown: "00:08"))
        let data = try #require(png(v))
        try data.write(to: Self.dir.appendingPathComponent("heads-up.png"))
        #expect(v.label.stringValue == "Rest in 00:08")
    }

    /// The four menu-bar icon states, drawn on a light and a dark strip like the real menu bar.
    @Test func menuBarIcons() throws {
        let modes: [(IconMode, Double)] = [(.working, 0.0), (.working, 0.35), (.working, 0.8), (.resting, 1), (.off, 0), (.away, 0)]
        let cell: CGFloat = 26, scale: CGFloat = 4
        let size = NSSize(width: cell * CGFloat(modes.count), height: cell * 2)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.15, alpha: 1), NSColor.white)].enumerated() {
            bg.setFill()
            NSRect(x: 0, y: CGFloat(row) * cell, width: size.width, height: cell).fill()
            for (i, (mode, progress)) in modes.enumerated() {
                let img = IconRenderer.image(mode: mode, progress: progress)
                let r = NSRect(x: CGFloat(i) * cell + 4, y: CGFloat(row) * cell + 4, width: 18, height: 18)
                // Tint the template image the way the menu bar does.
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    fg.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: Self.dir.appendingPathComponent("menu-bar-icons.png"))
    }
}

@MainActor
@Suite("Services")
struct ServiceTests {
    @Test(arguments: [Chime.restStart, .restEnd])
    func chimeSoundsShipWithMacOS(_ chime: Chime) {
        let sound = SystemChimePlayer().sound(for: chime)
        #expect(sound != nil, "missing system sound \(SystemChimePlayer.soundName(for: chime))")
        #expect((sound?.duration ?? 0) > 0.1)
    }

    @Test func presentationLockRestores() {
        _ = NSApplication.shared
        let lock = PresentationFocusLock()
        let before = NSApp.presentationOptions
        lock.lock()
        lock.unlock()
        #expect(NSApp.presentationOptions == before)
    }
}
