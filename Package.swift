// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SourceSound",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SourceSound", targets: ["SourceSound"])
    ],
    targets: [
        .executableTarget(
            name: "SourceSound",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .testTarget(
            name: "SourceSoundTests",
            dependencies: ["SourceSound"]
        )
    ]
)
