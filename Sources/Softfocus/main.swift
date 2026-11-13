import AppKit
import SoftfocusApp

let app = NSApplication.shared
let delegate = AppCoordinator(config: .fromEnvironment())
app.delegate = delegate
app.run()
