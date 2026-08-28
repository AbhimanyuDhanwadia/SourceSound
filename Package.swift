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
            dependencies: ["SourceSoundAtomics"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "SourceSoundAtomics",
            path: "Sources/SourceSoundAtomics",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "SourceSoundTests",
            dependencies: ["SourceSound"]
        )
    ]
)
