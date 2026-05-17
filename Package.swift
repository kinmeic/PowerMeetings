// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PowerMeetings",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PowerMeetings", targets: ["PowerMeetings"])
    ],
    targets: [
        .executableTarget(
            name: "PowerMeetings",
            path: "Sources/PowerMeetings"
        )
    ]
)
