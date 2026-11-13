import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The test-control channel. Only opened when the app is launched with
// SOFTFOCUS_CONTROL_SOCKET set, so end-to-end tests can drive the real app.
// Newline-delimited JSON over a Unix domain socket.

public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case state            // cycle snapshot
        case ui               // window/UI snapshot
        case press            // press a control by identifier (see ControlTarget)
        case key              // send a key to the rest card
        case idle             // override the idle-time reading
        case presence         // simulate sleep/lock (away=true) or wake (away=false)
        case settings         // replace settings, as the Settings window would
        case renderCard       // render the rest card to a PNG at `path`
        case url              // handle a softfocus:// URL, as LaunchServices would
        case renderSettings   // render the Settings window to a PNG at `path`
        case appleScript      // run the AppleScript source in `path` inside the app, against itself
                              // (exercises the scripting dictionary without an Automation prompt)
        case loginItem        // test login item only: change its state behind the app's back
                              // (key = a LoginItemState), as System Settings would
    }

    public var cmd: Command
    public var target: String?
    public var key: String?
    public var shift: Bool?
    public var seconds: Double?
    public var away: Bool?
    public var settings: Settings?
    public var path: String?

    public init(_ cmd: Command, target: String? = nil, key: String? = nil, shift: Bool? = nil,
                seconds: Double? = nil, away: Bool? = nil, settings: Settings? = nil, path: String? = nil) {
        self.cmd = cmd
        self.target = target
        self.key = key
        self.shift = shift
        self.seconds = seconds
        self.away = away
        self.settings = settings
        self.path = path
    }
}

/// Identifiers of pressable controls. Also used as accessibility identifiers.
public enum ControlTarget: String, CaseIterable, Sendable {
    case cardSnooze = "card.snooze"            // main part of the split button: 1 minute
    case cardSnooze5 = "card.snooze.5"         // menu item
    case cardSnooze15 = "card.snooze.15"       // menu item
    case cardFinish = "card.finish"
    case headsUpSnooze = "headsup.snooze"
    case headsUpRestNow = "headsup.restNow"
    case menuRestNow = "menu.restNow"
    case menuPostpone = "menu.postpone"
    case menuRestart = "menu.restart"
    case menuToggle = "menu.toggle"
    case menuSettings = "menu.settings"
    case menuQuit = "menu.quit"
}

/// Whether the app is registered to open at login, as macOS reports it.
public enum LoginItemState: String, Codable, Sendable, CaseIterable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings › Login Items.
    case requiresApproval

    /// The "Open at login" toggle shows on for anything the user asked for.
    public var isOn: Bool { self != .disabled }
}

/// Accessibility identifiers of the Settings controls. Tests drive the window through these.
public enum SettingsID {
    public static let window = "settings"
    public static let enabled = "settings.enabled"
    public static let workInterval = "settings.workInterval"
    public static let restLength = "settings.restLength"
    public static let headsUp = "settings.headsUp"
    public static let launchAtLogin = "settings.launchAtLogin"
    public static let loginItemNote = "settings.loginItem.note"
    public static let openLoginItems = "settings.loginItem.open"
    public static let menuBar = "settings.menuBar"
    public static let dock = "settings.dock"
    public static let headlessNote = "settings.headless.note"
    public static let strict = "settings.strict"
    public static let autoFinish = "settings.autoFinish"
    public static let sounds = "settings.sounds"
    public static let smartReset = "settings.smartReset"
    public static func hook(_ which: Hook, _ part: String) -> String { "settings.hook.\(which.rawValue).\(part)" }
}

public struct StateSnapshot: Codable, Sendable, Equatable {
    public var phase: String
    public var secondsUntilRest: Double?
    public var canSnooze: Bool
    public var canFinish: Bool
    public var canQuit: Bool
    public var focusLocked: Bool
    public var chimeLooping: Bool
    public var statusLine: String
    public var settings: Settings

    public init(cycle: Cycle, now: Date) {
        phase = cycle.phase.name
        secondsUntilRest = cycle.secondsUntilRest(at: now)
        canSnooze = cycle.canSnooze
        canFinish = cycle.canFinish
        canQuit = cycle.canQuit
        focusLocked = cycle.focusLocked
        chimeLooping = cycle.chimeLooping
        statusLine = cycle.statusLine(at: now)
        settings = cycle.settings
    }
}

public struct Rect: Codable, Sendable, Equatable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct WindowSnapshot: Codable, Sendable, Equatable {
    public var windowNumber: Int
    public var frame: Rect
    public var level: Int
    public var alpha: Double
    public var visible: Bool
    public var isKey: Bool
    public init(windowNumber: Int, frame: Rect, level: Int, alpha: Double, visible: Bool, isKey: Bool) {
        self.windowNumber = windowNumber; self.frame = frame; self.level = level
        self.alpha = alpha; self.visible = visible; self.isKey = isKey
    }
}

public struct CardSnapshot: Codable, Sendable, Equatable {
    public var window: WindowSnapshot
    public var headline: String
    public var elapsed: String
    public var remaining: String
    public var progress: Double
    public var snoozeEnabled: Bool
    public var finishEnabled: Bool
    public var snoozeMenu: [String]
    public init(window: WindowSnapshot, headline: String, elapsed: String, remaining: String, progress: Double,
                snoozeEnabled: Bool, finishEnabled: Bool, snoozeMenu: [String]) {
        self.window = window; self.headline = headline; self.elapsed = elapsed; self.remaining = remaining
        self.progress = progress; self.snoozeEnabled = snoozeEnabled; self.finishEnabled = finishEnabled
        self.snoozeMenu = snoozeMenu
    }
}

public struct UISnapshot: Codable, Sendable, Equatable {
    public var screens: [Rect]
    public var shields: [WindowSnapshot]
    public var card: CardSnapshot?
    public var headsUp: WindowSnapshot?
    public var headsUpText: String?
    public var statusItemVisible: Bool
    public var menuItems: [String]
    public var settingsWindowVisible: Bool
    public var activationPolicy: String
    public var presentationOptions: UInt
    public var hooksRun: [String]
    public var chimesPlayed: [String]
    public var loginItem: LoginItemState
    public var loginItemMessage: String?
    public var loginItemSettingsOpened: Int
    public init(screens: [Rect], shields: [WindowSnapshot], card: CardSnapshot?, headsUp: WindowSnapshot?,
                headsUpText: String?, statusItemVisible: Bool, menuItems: [String], settingsWindowVisible: Bool,
                activationPolicy: String, presentationOptions: UInt, hooksRun: [String], chimesPlayed: [String],
                loginItem: LoginItemState, loginItemMessage: String?, loginItemSettingsOpened: Int) {
        self.screens = screens; self.shields = shields; self.card = card; self.headsUp = headsUp
        self.headsUpText = headsUpText; self.statusItemVisible = statusItemVisible; self.menuItems = menuItems
        self.settingsWindowVisible = settingsWindowVisible; self.activationPolicy = activationPolicy
        self.presentationOptions = presentationOptions; self.hooksRun = hooksRun; self.chimesPlayed = chimesPlayed
        self.loginItem = loginItem
        self.loginItemMessage = loginItemMessage
        self.loginItemSettingsOpened = loginItemSettingsOpened
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var state: StateSnapshot?
    public var ui: UISnapshot?
    /// Result of an appleScript request, as text.
    public var result: String?

    public init(ok: Bool, error: String? = nil, state: StateSnapshot? = nil, ui: UISnapshot? = nil, result: String? = nil) {
        self.ok = ok; self.error = error; self.state = state; self.ui = ui; self.result = result
    }

    public static func failure(_ message: String) -> ControlResponse { .init(ok: false, error: message) }
}

// MARK: Transport

public enum ControlSocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case pathTooLong
    case closed

    public var description: String {
        switch self {
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .pathTooLong: "socket path too long"
        case .closed: "connection closed"
        }
    }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw ControlSocketError.pathTooLong }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return addr
}

private func readLine(_ fd: Int32, buffer: inout [UInt8]) -> Data? {
    while true {
        if let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<nl])
            buffer.removeSubrange(...nl)
            return line
        }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return nil }
        buffer.append(contentsOf: chunk[..<n])
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var bytes = [UInt8](data)
    bytes.append(0x0A)
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return false }
        off += n
    }
    return true
}

/// Serves control requests on a background thread; each request is handed to `handler`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let lock = NSLock()

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        var addr = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw ControlSocketError.system("bind", errno) }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { close(fd); throw ControlSocketError.system("listen", errno) }
        lock.withLock { listenFD = fd }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "softfocus.control"
        thread.start()
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in let fd = listenFD; listenFD = -1; return fd }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR) // wakes the blocked accept()
            close(fd)
        }
        unlink(path)
    }

    /// Runs on its own thread until the listening socket is closed.
    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            noSigPipe(client) // a client that hangs up must not kill the app
            serve(client)
            close(client)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer: [UInt8] = []
        while let line = readLine(fd, buffer: &buffer) {
            let response: ControlResponse
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                response = blockingHandle(request)
            } else {
                response = .failure("malformed request")
            }
            guard let data = try? JSONEncoder().encode(response), writeAll(fd, data) else { return }
        }
    }

    private final class Box: @unchecked Sendable { var value: ControlResponse = .failure("no response") }

    private func blockingHandle(_ request: ControlRequest) -> ControlResponse {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task {
            box.value = await handler(request)
            done.signal()
        }
        done.wait()
        return box.value
    }
}

func noSigPipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Synchronous client used by end-to-end tests.
public final class ControlClient {
    private let fd: Int32
    private var buffer: [UInt8] = []

    public init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        var addr = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw ControlSocketError.system("connect", e) }
        noSigPipe(fd)
        self.fd = fd
    }

    deinit { close(fd) }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let data = try JSONEncoder().encode(request)
        guard writeAll(fd, data) else { throw ControlSocketError.closed }
        guard let line = readLine(fd, buffer: &buffer) else { throw ControlSocketError.closed }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }
}
