// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceToTextMac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "VoiceToTextMac",
            targets: ["VoiceToTextMacApp"]
        ),
    ],
    targets: [
        .target(
            name: "VoiceToTextMac",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "VoiceToTextMacApp",
            dependencies: ["VoiceToTextMac"],
            path: "Sources/VoiceToTextMacApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    "-sectcreate",
                    "-Xlinker",
                    "__TEXT",
                    "-Xlinker",
                    "__info_plist",
                    "-Xlinker",
                    "Supporting/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "VoiceToTextMacTestRunner",
            dependencies: ["VoiceToTextMac"],
            path: "TestsRunner",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    "-sectcreate",
                    "-Xlinker",
                    "__TEXT",
                    "-Xlinker",
                    "__info_plist",
                    "-Xlinker",
                    "Supporting/Info.plist",
                ]),
            ]
        ),
    ]
)
