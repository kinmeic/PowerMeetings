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
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "PowerMeetings",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/PowerMeetings"
        )
    ]
)