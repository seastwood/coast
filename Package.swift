// swift-tools-version:5.9
// Coast: trackball-style cursor inertia for macOS trackpads, as a menu bar app.
// Build the app and dmg with ./build_dmg.sh; `swift run` runs it unbundled for development.
import PackageDescription

let package = Package(
    name: "Coast",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "Coast", path: "Sources/Coast"),
    ]
)
