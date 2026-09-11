// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacPulse",
            path: "Sources/MacPulse",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
