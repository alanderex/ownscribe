// swift-tools-version: 5.9
import PackageDescription

// Builds and tests only the Foundation-only logic in Sources/Logic.
//
// The app itself is not built from here: build-app.sh compiles every file under
// Sources (Logic included) into one module, and project.yml does the same for
// Xcode. So code in Logic must never `import Logic` or reach for app types, and
// the tests use `@testable import Logic`.
//
// The platform matches the app's deployment target. SwiftPM's default would let
// APIs newer than macOS 14 compile here and then fail in the app build.
let package = Package(
    name: "OwnscribeLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Logic", path: "Sources/Logic"),
        .testTarget(name: "LogicTests", dependencies: ["Logic"], path: "Tests/LogicTests"),
    ]
)
