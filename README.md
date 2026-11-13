# Softfocus

A menu-bar app for macOS 14+ (Apple Silicon and Intel) that reminds you to rest your eyes. After each work period it dims every display and shows a rest card with a countdown. You can snooze or finish the rest, or (in strict mode) wait it out.

## Features

- Work / rest cycle with a heads-up panel a few seconds before each rest.
- **Rest overlay** on every display, plus a rest card:
  - a progress ring with the time left in the middle;
  - a quiet **Snooze** capsule with a chevron for 5 and 15 minutes, and a filled **Finish** button;
  - keycap hints for the shortcuts.

  When the rest is done the ring turns green with a checkmark, and Finish becomes "Back to Work".
- Keys on the card: Esc snoozes 1 min, ⇧Esc snoozes 5 min, Return or Space finishes. Keys are ignored for the first 0.5 s.
- **Strict mode**: no snooze or finish until the rest is over. Dock, menu bar, app switching and Force Quit are blocked, and Quit is refused (logout, restart and shutdown always go through).
  - Settings, links and scripts can't switch the rest off, make it non-strict or shorten it.
- **Auto-finish** (close the rest by itself) or a looping reminder chime until you press Finish.
- **Smart reset** ("Count time away from the Mac as a rest"):
  - **Away long enough while working** (no input for the rest length plus about a minute per 15 minutes of work), **or the Mac sleeps, locks or starts the screen saver:** the countdown pauses. A full work period starts at your first input or unlock.
  - **A rest falls due while you're idle:**
    - idle for at least a minute (and at least the rest length): no card appears for an empty desk;
    - idle 15 s or more but less than that: the time counts, and the card starts part-way through, always leaving at least 10 s.
  - **Locking the screen during a rest:** the rest keeps running, strict or not. If it runs out while you're still away, the card closes quietly and work restarts when you're back.
  - **You don't come back after a rest ends:** the reminder chime stops after about 30 s, and later the card closes quietly.
  - **A video or slideshow keeping the display awake:** this counts as using the Mac, so breaks still come.
  - **Setting off:** idle time and lock or sleep are ignored.
- Start and end **hooks**: shell scripts, executables, AppleScripts or Automator workflows.
- Optional Dock icon and menu-bar icon. When both are hidden, opening the app again shows Settings.
- **Settings window** with toolbar tabs:
  - **General:** schedule, heads-up, open at login, and Dock / menu-bar icons.
  - **Rest:** strict mode, auto-finish, sounds, and smart reset.
  - **Scripts:** start and end hooks.

  Durations are typed exactly, with a stepper (next round value), a sec/min unit menu, and one-click presets (20 min / 20 sec and others). A value out of range is clamped, and a note shows the allowed range.
- **Open at login** via `SMAppService.mainApp`. macOS owns the truth: the toggle re-reads the system state at launch, on activation and when Settings opens. If macOS wants the user's approval, Settings says so and offers **Open Login Items…**. A failure shows the error and turns the toggle back off.
- Automation through an AppleScript dictionary (`tell application "Softfocus" to rest now`) and the `softfocus://` URL scheme: `rest-now`, `finish`, `snooze?minutes=5`, `enable`, `disable`, `toggle`, `restart`, `settings`.

## Layout

| Target | What it holds |
|---|---|
| `SoftfocusCore` | Pure logic, no AppKit. Contains the `Cycle` state machine (events in, effects out, time passed in explicitly), settings and limits, display text, key rules, URL commands, presence tracking, and the test-control protocol. |
| `SoftfocusApp` | AppKit and SwiftUI. Contains `AppCoordinator`, which applies the cycle's effects, plus the rest overlay, heads-up panel, status item, Settings window, and system services (idle, presence, focus lock, chimes, hooks, login item), each behind a protocol. |
| `Softfocus` | `main.swift`, which only starts the app. |

Everything the app decides goes through `Cycle.handle(_:at:) -> [Effect]`. The coordinator only turns effects into windows, sounds and processes, so all the rules can be tested without a screen.

## Install

Download `Softfocus.zip` from [Releases](../../releases), unzip it and move `Softfocus.app` to `/Applications`.

The release is ad-hoc signed, not notarized, so macOS blocks the first launch. Either right-click the app and choose **Open**, or allow it under *System Settings › Privacy & Security* ("Open Anyway"). From Terminal you can also run:

```sh
xattr -dr com.apple.quarantine /Applications/Softfocus.app
```

## Build

```sh
scripts/build-app.sh                 # release, universal → build/Softfocus.app (ad-hoc signed)
CONFIG=debug ARCHS=arm64 scripts/build-app.sh
SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
```

Requires Xcode 16+ / Swift 6. No third-party dependencies.

## Test

```sh
swift test --skip SoftfocusE2ETests    # unit + in-process view tests, < 1 s
scripts/test-e2e.sh                  # builds the app, then drives it end to end (~20 s)
```

- **`SoftfocusCoreTests`** run the cycle with a fake clock: scheduling, heads-up, snooze, strict mode, auto-finish, idle and presence, settings changes, formatting, keys, URL parsing, and the control socket.
- **`SoftfocusAppTests`** build the real AppKit views in-process: card rendering, disabled buttons in strict mode, the snooze menu, and the menu-bar icon.
- **`SoftfocusE2ETests`** launch the built `Softfocus.app` as a separate process and drive it like a user would. They operate the Settings window through its real controls via the macOS accessibility API, including the fields, steppers, presets, toggles and tabs. That needs your terminal allowed under *Privacy & Security › Accessibility*; without it those tests are skipped with that message. Each run uses its own defaults domain and is cleaned up afterwards. They check:
  - the windows the app really puts on screen (levels, frames, key focus, and the window server's own window list)
  - that hook scripts actually ran
  - that settings persist across a relaunch
  - Dock and menu-bar visibility, the URL commands, and quitting
  - open-at-login: registering, approval needed, errors, and changes made in System Settings

  Renders of the rest card and of each Settings tab are saved to `build/e2e-artifacts/`, and `swift test` writes card previews to `build/previews/`.

  `SOFTFOCUS_E2E_REAL_LOGIN=1 scripts/test-e2e.sh --filter openAtLoginWithRealMacOS` also registers the built app with macOS for real and removes it again. macOS shows a "login item added" notification.

**Design for testing.** When the app is started with `SOFTFOCUS_TESTING=1` it:
- allows short durations, uses silent chimes and a fake login item;
- uses the defaults domain given in `SOFTFOCUS_DEFAULTS_SUITE`;
- uses a fake login item unless `SOFTFOCUS_REAL_LOGIN_ITEM=1`. `SOFTFOCUS_FAKE_LOGIN=requiresApproval|fail` picks how it answers;
- opens a JSON control socket at `SOFTFOCUS_CONTROL_SOCKET`. Over the socket a test can read the state and UI snapshot, press controls, send keys, inject idle or presence changes, change settings, render the card, or open URLs.

`SOFTFOCUS_FAKE_IDLE` fixes the idle reading so the tests do not depend on someone touching the Mac. Without these variables the socket is never opened.

> The end-to-end tests briefly dim your screens and show rest cards. Don't type while they run.
