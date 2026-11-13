import AppKit
import SoftfocusCore

// AppleScript commands declared in Resources/Softfocus.sdef. Each maps to the same
// ExternalCommand the URL scheme uses, so both paths behave identically.

@MainActor
private func runExternal(_ command: ExternalCommand) {
    AppCoordinator.shared?.run(command)
}

@objc(SoftfocusRestNowCommand)
final class SoftfocusRestNowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { runExternal(.restNow) }
        return nil
    }
}

@objc(SoftfocusFinishCommand)
final class SoftfocusFinishCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { runExternal(.finish) }
        return nil
    }
}

@objc(SoftfocusSnoozeCommand)
final class SoftfocusSnoozeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let minutes = (evaluatedArguments?["minutes"] as? NSNumber)?.doubleValue ?? 1
        guard minutes > 0 else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Minutes must be greater than zero."
            return nil
        }
        MainActor.assumeIsolated { runExternal(.snooze(minutes * 60)) }
        return nil
    }
}

@objc(SoftfocusRestartCommand)
final class SoftfocusRestartCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { runExternal(.restartCountdown) }
        return nil
    }
}
