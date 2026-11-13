import Foundation
import Testing
@testable import SoftfocusCore

/// Drives a Cycle with a fake clock.
struct Driver {
    var cycle: Cycle
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    init(_ configure: (inout Settings) -> Void = { _ in }) {
        var s = Settings()
        s.workSeconds = 600
        s.restSeconds = 60
        configure(&s)
        cycle = Cycle(settings: s, now: now)
    }

    @discardableResult
    mutating func send(_ e: Event) -> [Effect] { cycle.handle(e, at: now) }

    /// Advances time in 1-second ticks, collecting effects.
    @discardableResult
    mutating func advance(_ seconds: TimeInterval) -> [Effect] {
        var fx: [Effect] = []
        var left = seconds
        while left > 0 {
            let step = min(1, left)
            now += step
            left -= step
            fx += cycle.handle(.tick, at: now)
        }
        return fx
    }

    var phase: String { cycle.phase.name }
}

@Suite("Work countdown")
struct WorkCountdownTests {
    @Test func startsWorkingWhenEnabled() {
        let d = Driver()
        #expect(d.phase == "working")
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func startsOffWhenDisabled() {
        let d = Driver { $0.enabled = false }
        #expect(d.cycle.phase == .off)
        #expect(d.cycle.secondsUntilRest(at: d.now) == nil)
    }

    @Test func headsUpAppearsOnceBeforeRest() {
        var d = Driver()
        #expect(d.advance(589).isEmpty)
        #expect(d.advance(1) == [.showHeadsUp])
        #expect(d.advance(5).isEmpty)
        #expect(d.cycle.headsUp(at: d.now)?.countdown == "00:05")
    }

    @Test func noHeadsUpWhenDisabledOrWorkTooShort() {
        var a = Driver { $0.headsUpSeconds = 0 }
        #expect(!a.advance(599).contains(.showHeadsUp))
        var b = Driver { $0.workSeconds = 8; $0.headsUpSeconds = 10 }
        #expect(!b.advance(7).contains(.showHeadsUp))
    }

    @Test func restStartsAtDueTime() {
        var d = Driver()
        let fx = d.advance(600)
        #expect(fx == [.showHeadsUp, .hideHeadsUp, .runHook(.start), .showRest, .playChime(.restStart)])
        #expect(d.phase == "resting")
    }

    @Test func noChimesWhenSoundsOff() {
        var d = Driver { $0.soundsOn = false }
        #expect(!d.advance(600).contains(.playChime(.restStart)))
    }

    @Test func workProgressFillsUp() {
        var d = Driver()
        #expect(d.cycle.workProgress(at: d.now) == 0)
        d.advance(300)
        #expect(d.cycle.workProgress(at: d.now) == 0.5)
    }

    @Test func postponeAddsToRemainingTime() {
        var d = Driver()
        d.advance(100)
        d.send(.snooze(300))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 800)
    }

    @Test func postponeDuringHeadsUpHidesItAndShowsAgainLater() {
        var d = Driver()
        d.advance(595)
        #expect(d.send(.snooze(300)) == [.hideHeadsUp])
        #expect(d.cycle.secondsUntilRest(at: d.now) == 305)
        #expect(d.advance(295) == [.showHeadsUp])
    }

    @Test func restartCountdown() {
        var d = Driver()
        d.advance(400)
        d.send(.restartCountdown)
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }
}

@Suite("Rest")
struct RestTests {
    @Test func restNowFromWorking() {
        var d = Driver()
        let fx = d.send(.restNow)
        #expect(fx == [.runHook(.start), .showRest, .playChime(.restStart)])
        #expect(d.cycle.canFinish && d.cycle.canSnooze)
    }

    @Test func restNowIgnoredWhileResting() {
        var d = Driver()
        d.send(.restNow)
        #expect(d.send(.restNow).isEmpty)
    }

    @Test func restCompletesAndWaitsForFinish() {
        var d = Driver()
        d.send(.restNow)
        let fx = d.advance(60)
        #expect(fx == [.startChimeLoop])
        #expect(d.phase == "restDone")
        #expect(d.cycle.chimeLooping)
        let card = d.cycle.restCard(at: d.now)
        #expect(card?.isComplete == true)
        #expect(card?.remaining == "00:00")
        #expect(card?.progress == 1)
    }

    @Test func finishStartsFreshWork() {
        var d = Driver()
        d.send(.restNow)
        d.advance(60)
        let fx = d.send(.finish)
        #expect(fx == [.hideRest, .stopChime, .runHook(.end)])
        #expect(d.phase == "working")
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func autoFinishClosesByItself() {
        var d = Driver { $0.autoFinish = true }
        d.send(.restNow)
        let fx = d.advance(60)
        #expect(fx == [.playChime(.restEnd), .hideRest, .runHook(.end)])
        #expect(d.phase == "working")
    }

    @Test func snoozeDuringRest() {
        var d = Driver()
        d.send(.restNow)
        d.advance(10)
        #expect(d.send(.snooze(60)) == [.hideRest, .runHook(.end)])
        #expect(d.cycle.secondsUntilRest(at: d.now) == 60)
    }

    @Test func cardShowsElapsedAndRemaining() {
        var d = Driver { $0.restSeconds = 180 }
        d.send(.restNow)
        d.advance(12)
        let card = d.cycle.restCard(at: d.now)
        #expect(card?.elapsed == "00:12")
        #expect(card?.remaining == "02:48")
        #expect(abs((card?.progress ?? 0) - 12.0 / 180) < 1e-9)
    }

    @Test func finishWhenDisabledGoesOff() {
        var d = Driver()
        d.send(.restNow)
        var s = d.cycle.settings
        s.enabled = false
        d.send(.settingsChanged(s))
        #expect(d.cycle.phase == .off)
    }
}

@Suite("Strict mode")
struct StrictTests {
    @Test func locksAndBlocksEarlyExit() {
        var d = Driver { $0.strictMode = true }
        let fx = d.send(.restNow)
        #expect(fx.contains(.lockFocus))
        #expect(d.cycle.focusLocked)
        #expect(!d.cycle.canSnooze && !d.cycle.canFinish && !d.cycle.canQuit)
        #expect(d.send(.snooze(60)).isEmpty)
        #expect(d.send(.finish).isEmpty)
        #expect(d.phase == "resting")
    }

    @Test func finishAllowedOnceRestIsOver() {
        var d = Driver { $0.strictMode = true }
        d.send(.restNow)
        d.advance(60)
        #expect(d.cycle.canFinish)
        #expect(!d.cycle.canSnooze)
        let fx = d.send(.finish)
        #expect(fx == [.hideRest, .stopChime, .unlockFocus, .runHook(.end)])
        #expect(d.cycle.canQuit)
    }

    @Test func strictRestCannotBeMadeNonStrictOrShorter() {
        var d = Driver { $0.strictMode = true }
        d.send(.restNow)
        var s = d.cycle.settings
        s.strictMode = false
        s.restSeconds = 5
        #expect(d.send(.settingsChanged(s)).isEmpty)
        #expect(d.cycle.focusLocked && !d.cycle.canSnooze && !d.cycle.canFinish)
        #expect(d.cycle.restCard(at: d.now)?.remaining == "01:00")
        s.restSeconds = 120 // longer is fine
        d.send(.settingsChanged(s))
        #expect(d.cycle.restCard(at: d.now)?.remaining == "02:00")
        d.advance(120)
        d.send(.finish)
        d.send(.restNow)
        #expect(!d.cycle.focusLocked && d.cycle.canFinish) // the next rest is not strict
    }

    @Test func headsUpSnoozeStillAllowed() {
        var d = Driver { $0.strictMode = true }
        d.advance(595)
        #expect(d.cycle.canSnooze)
    }
}

@Suite("Idle and presence")
struct IdlePresenceTests {
    @Test func thresholdGrowsWithWorkLength() {
        #expect(SmartReset.idleThreshold(work: 900, rest: 60) == 120)
        #expect(SmartReset.idleThreshold(work: 1200, rest: 120) > 120 + 60)
        #expect(SmartReset.idleThreshold(work: 3600, rest: 120) > SmartReset.idleThreshold(work: 1200, rest: 120))
    }

    @Test func longIdlePausesAndReturnStartsFreshWork() {
        var d = Driver()
        d.advance(500)
        let threshold = SmartReset.idleThreshold(work: 600, rest: 60)
        d.send(.idleSample(threshold - 1))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 100)
        d.send(.idleSample(threshold))
        #expect(d.cycle.phase == .away(byIdle: true))
        #expect(d.cycle.statusLine(at: d.now) == "Paused while you are away")
        // Still idle for an hour: nothing happens, no rest pops up.
        d.send(.idleSample(threshold + 3600))
        #expect(d.advance(3600).isEmpty)
        // First input: a full work period from that moment.
        d.send(.idleSample(0.5))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func idleIgnoredWhenSmartResetOff() {
        var d = Driver { $0.smartReset = false }
        d.advance(500)
        d.send(.idleSample(10_000))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 100)
    }

    @Test func awayWhileWorkingPausesAndReturnRestarts() {
        var d = Driver()
        d.advance(300)
        #expect(d.send(.presence(away: true)).isEmpty)
        #expect(d.cycle.phase == .away(byIdle: false))
        #expect(d.advance(10_000).isEmpty)
        d.send(.presence(away: false))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func lockingDuringARestKeepsResting() {
        var d = Driver()
        d.send(.restNow)
        d.advance(10)
        #expect(d.send(.presence(away: true)).isEmpty)
        #expect(d.phase == "resting")
        d.advance(20)
        d.send(.presence(away: false)) // back before the rest ends
        d.advance(30)
        #expect(d.phase == "restDone") // the card waits for Finish, as usual
    }

    @Test func lockingCannotEndAStrictRest() {
        var d = Driver { $0.strictMode = true }
        d.send(.restNow)
        let fx = d.send(.presence(away: true)) + d.send(.presence(away: false))
        #expect(fx.isEmpty)
        #expect(d.cycle.focusLocked && d.phase == "resting")
    }

    @Test func presenceIgnoredWhenSmartResetOff() {
        var d = Driver { $0.smartReset = false }
        d.advance(300)
        d.send(.presence(away: true))
        d.advance(5)
        d.send(.presence(away: false))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 295)
    }

    @Test func awayWhileOffStaysOff() {
        var d = Driver { $0.enabled = false }
        d.send(.presence(away: true))
        d.send(.presence(away: false))
        #expect(d.cycle.phase == .off)
    }

    @Test func trackerCombinesReasons() {
        var t = PresenceTracker()
        #expect(t.set(.locked, true) == true)
        #expect(t.set(.screenSaver, true) == nil)
        #expect(t.set(.screenSaver, false) == nil)
        #expect(t.set(.locked, false) == false)
        #expect(t.set(.displaySleep, true) == true)
        #expect(t.set(.systemSleep, true) == nil)
        #expect(t.set(.systemSleep, false) == false) // wake clears display sleep too
    }
}

@Suite("Enable and settings")
struct EnableSettingsTests {
    @Test func disablingClosesEverything() {
        var d = Driver()
        d.send(.restNow)
        d.advance(60) // chime looping
        let fx = d.send(.setEnabled(false))
        #expect(fx == [.hideRest, .stopChime, .runHook(.end)])
        #expect(d.cycle.phase == .off)
        #expect(d.send(.setEnabled(true)).isEmpty)
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func changingWorkIntervalRestartsCountdown() {
        var d = Driver()
        d.advance(100)
        var s = d.cycle.settings
        s.workSeconds = 1200
        d.send(.settingsChanged(s))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 1200)
    }

    @Test func turningSoundsOffStopsLoop() {
        var d = Driver()
        d.send(.restNow)
        d.advance(60)
        var s = d.cycle.settings
        s.soundsOn = false
        #expect(d.send(.settingsChanged(s)) == [.stopChime])
    }
}

@Suite("Inactivity")
struct InactivityTests {
    /// Driver with 10 min work, 60 s rest; threshold ≈ 60 + 60·(600/900)^0.7 ≈ 107 s.
    var threshold: TimeInterval { SmartReset.idleThreshold(work: 600, rest: 60) }

    @Test func idleThroughDueTimeSkipsTheRestCard() {
        var d = Driver()
        d.advance(590)
        d.send(.idleSample(70)) // away from the desk for longer than a rest
        let fx = d.advance(10)
        #expect(!fx.contains(.showRest) && !fx.contains(.runHook(.start)))
        #expect(d.cycle.phase == .away(byIdle: true))
        d.send(.idleSample(0))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func shortIdleBeforeRestCountsTowardsIt() {
        var d = Driver()
        d.advance(599)
        d.send(.idleSample(20))
        d.advance(1)
        let card = d.cycle.restCard(at: d.now)
        #expect(card?.elapsed == "00:20" && card?.remaining == "00:40")
        d.advance(40)
        #expect(d.phase == "restDone")
    }

    @Test func briefPausesDoNotCount() {
        var d = Driver()
        d.advance(599)
        d.send(.idleSample(SmartReset.creditIdle - 1))
        d.advance(1)
        #expect(d.cycle.restCard(at: d.now)?.elapsed == "00:00")
    }

    @Test func idleDuringRestIsFineThenEmptyDeskClosesCardQuietly() {
        var d = Driver()
        d.send(.restNow)
        // Walked away at the start of the rest: the rest runs normally.
        for t in stride(from: 10.0, through: 60, by: 10) { d.advance(10); d.send(.idleSample(t)) }
        #expect(d.phase == "restDone" && d.cycle.chimeLooping)
        // Still gone past the threshold: card closes, chime stops, waits for return.
        d.advance(threshold - 60)
        let fx = d.send(.idleSample(threshold))
        #expect(fx == [.hideRest, .stopChime, .runHook(.end)])
        #expect(d.cycle.phase == .away(byIdle: true))
        d.send(.idleSample(0))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func idleDoesNotEndARunningRest() {
        var d = Driver { $0.restSeconds = 600 }
        d.send(.restNow)
        d.advance(300)
        d.send(.idleSample(10_000))
        #expect(d.phase == "resting")
    }

    @Test func strictRestDoneThenIdleUnlocks() {
        var d = Driver { $0.strictMode = true }
        d.send(.restNow)
        d.advance(60)
        #expect(d.cycle.focusLocked)
        let fx = d.send(.idleSample(threshold + 1))
        #expect(fx.contains(.unlockFocus) && !d.cycle.focusLocked)
    }

    @Test func smartResetOffIgnoresIdleEverywhere() {
        var d = Driver { $0.smartReset = false }
        d.advance(599)
        d.send(.idleSample(10_000))
        #expect(d.advance(1).contains(.showRest))
        #expect(d.cycle.restCard(at: d.now)?.elapsed == "00:00") // no credit either
        d.advance(60)
        d.send(.idleSample(10_000))
        #expect(d.phase == "restDone")
    }

    @Test func turningSmartResetOffWhileIdleResumes() {
        var d = Driver()
        d.send(.idleSample(threshold))
        #expect(d.cycle.phase == .away(byIdle: true))
        var s = d.cycle.settings
        s.smartReset = false
        d.send(.settingsChanged(s))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func lockWhileIdleThenUnlockStartsWork() {
        var d = Driver()
        d.send(.idleSample(threshold))
        d.send(.presence(away: true))
        #expect(d.cycle.phase == .away(byIdle: false))
        d.send(.idleSample(0)) // input on the lock screen does not count
        #expect(d.cycle.phase == .away(byIdle: false))
        d.send(.presence(away: false))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func disablingWhileIdleThenReturnStaysOff() {
        var d = Driver()
        d.send(.idleSample(threshold))
        d.send(.setEnabled(false))
        #expect(d.cycle.phase == .off)
        d.send(.idleSample(0))
        #expect(d.cycle.phase == .off)
    }

    @Test func idlePhaseIsNamedForScripts() {
        var d = Driver()
        d.send(.idleSample(threshold))
        #expect(d.phase == "idle")
        d.send(.presence(away: true))
        #expect(d.phase == "away")
    }
}

@Suite("Review fixes")
struct ReviewFixTests {
    @Test func switchingOffDuringStrictRestWaitsForTheRestToEnd() {
        var d = Driver { $0.strictMode = true }
        d.send(.restNow)
        let refused = d.send(.setEnabled(false))
        #expect(refused.isEmpty)
        #expect(!d.cycle.settings.enabled) // remembered...
        #expect(d.phase == "resting" && d.cycle.focusLocked && !d.cycle.canFinish) // ...but the rest holds
        d.advance(60)
        d.send(.finish)
        #expect(d.cycle.phase == .off) // and applies afterwards
    }

    @Test func autoFinishSwitchedOnWhileWaitingFinishes() {
        var d = Driver()
        d.send(.restNow)
        d.advance(60)
        #expect(d.phase == "restDone")
        var s = d.cycle.settings
        s.autoFinish = true
        let fx = d.send(.settingsChanged(s))
        #expect(fx == [.hideRest, .stopChime, .runHook(.end)])
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func restLengthChangeAppliesToCurrentRest() {
        var d = Driver()
        d.send(.restNow)
        d.advance(30)
        var s = d.cycle.settings
        s.restSeconds = 20
        d.send(.settingsChanged(s))
        #expect(d.phase == "restDone") // already rested longer than the new length
        var e = Driver()
        e.send(.restNow)
        s = e.cycle.settings
        s.restSeconds = 120
        e.send(.settingsChanged(s))
        #expect(e.cycle.restCard(at: e.now)?.remaining == "02:00")
    }

    @Test func trackerClearEndsAway() {
        var t = PresenceTracker()
        let nothing = t.clear()
        #expect(!nothing)
        _ = t.set(.locked, true)
        let ended = t.clear()
        #expect(ended && !t.isAway)
    }
}

@Suite("Inactivity, round 2")
struct InactivityRound2Tests {
    @Test func readerOnShortRestIsNotSkipped() {
        var d = Driver { $0.restSeconds = 20 }
        d.advance(599)
        d.send(.idleSample(25)) // reading, hands off the keyboard
        #expect(d.advance(1).contains(.showRest))
        let card = d.cycle.restCard(at: d.now)
        #expect(card?.remaining == "00:10") // credited, but the card still shows 10 s
    }

    @Test func emptyDeskStillSkipsAfterAMinute() {
        var d = Driver { $0.restSeconds = 20 }
        d.advance(599)
        d.send(.idleSample(61))
        #expect(!d.advance(1).contains(.showRest))
        #expect(d.cycle.phase == .away(byIdle: true))
    }

    @Test func restRunningOutWhileLockedClosesQuietly() {
        var d = Driver()
        d.send(.restNow)
        d.send(.presence(away: true))
        let fx = d.advance(60)
        #expect(fx == [.hideRest, .runHook(.end)]) // no chime, no "rest complete" card
        #expect(d.cycle.phase == .away(byIdle: false))
        d.send(.idleSample(0)) // a wiggle on the lock screen does not restart work
        #expect(d.cycle.phase == .away(byIdle: false))
        d.send(.presence(away: false))
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }

    @Test func lockedAfterRestDoneClosesCard() {
        var d = Driver()
        d.send(.restNow)
        d.advance(60)
        let fx = d.send(.presence(away: true))
        #expect(fx == [.hideRest, .stopChime, .runHook(.end)])
        #expect(d.cycle.phase == .away(byIdle: false))
    }

    @Test func idleWhileLockedDoesNotStartWork() {
        var d = Driver()
        d.send(.idleSample(SmartReset.idleThreshold(work: 600, rest: 60)))
        d.send(.presence(away: true))
        d.send(.idleSample(0))
        #expect(d.cycle.phase == .away(byIdle: false))
    }

    @Test func strictLockAndRestEndWhileLocked() {
        var d = Driver { $0.strictMode = true; $0.autoFinish = true }
        d.send(.restNow)
        d.send(.presence(away: true))
        let fx = d.advance(60)
        #expect(fx.contains(.unlockFocus) && !d.cycle.focusLocked)
        #expect(d.cycle.phase == .away(byIdle: false))
    }
}

@Suite("Inactivity, round 3")
struct InactivityRound3Tests {
    @Test func presenceFlagSurvivesFinishAndIsClearedByReturn() {
        var d = Driver()
        d.send(.restNow)
        d.send(.presence(away: true))   // locked during the rest
        d.send(.presence(away: false))  // back
        #expect(!d.cycle.presenceAway)
        d.advance(60)
        #expect(d.phase == "restDone") // a normal end: chime and Finish
    }

    @Test func stalePresenceIsRecoverableFromIdlePause() {
        var d = Driver()
        d.send(.restNow)
        d.send(.presence(away: true))
        d.send(.snooze(60))            // e.g. via a script while the flag is stale
        d.send(.idleSample(SmartReset.idleThreshold(work: 600, rest: 60)))
        #expect(d.cycle.phase == .away(byIdle: true))
        d.send(.presence(away: false)) // what the app's recovery sends once someone is back
        #expect(d.cycle.secondsUntilRest(at: d.now) == 600)
    }
}
