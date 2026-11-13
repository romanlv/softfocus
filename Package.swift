// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Softfocus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Softfocus", targets: ["Softfocus"]),
    ],
    targets: [
        // Pure logic: no AppKit. Every rule of the rest cycle lives here.
        .target(name: "SoftfocusCore"),
        // AppKit/SwiftUI shell: windows, menu bar, system services.
        .target(name: "SoftfocusApp", dependencies: ["SoftfocusCore"]),
        // Thin entry point.
        .executableTarget(name: "Softfocus", dependencies: ["SoftfocusApp"]),

        .testTarget(name: "SoftfocusCoreTests", dependencies: ["SoftfocusCore"]),
        .testTarget(name: "SoftfocusAppTests", dependencies: ["SoftfocusApp", "SoftfocusCore"]),
        // Launches the built Softfocus.app and drives it over the control socket.
        .testTarget(name: "SoftfocusE2ETests", dependencies: ["SoftfocusCore"]),
    ]
)
