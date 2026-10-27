// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuickFolder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QuickFolder", targets: ["QuickFolder"])
    ],
    targets: [
        .executableTarget(
            name: "QuickFolder",
            path: "Sources/QuickFolder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
