// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CodexStatusBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexStatusBar", targets: ["CodexStatusBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "CodexStatusBar",
            dependencies: [
                "SwiftTerm",
            ],
            path: "Sources/CodexStatusBar"
        ),
        .testTarget(
            name: "CodexStatusBarTests",
            dependencies: [
                "CodexStatusBar",
                "SwiftTerm",
            ],
            path: "Tests/CodexStatusBarTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
