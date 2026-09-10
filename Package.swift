// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "MiniStat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MiniStat", targets: ["MiniStat"])
    ],
    targets: [
        .executableTarget(
            name: "MiniStat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "MiniStatTests",
            dependencies: ["MiniStat"]
        )
    ]
)
