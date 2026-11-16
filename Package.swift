// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchFill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchFill",
            path: "Sources/NotchFill",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
