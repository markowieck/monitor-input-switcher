// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MonitorInputSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "MonitorInputSwitcher",
            dependencies: [
                .product(name: "MQTTNIO", package: "mqtt-nio")
            ],
            path: "Sources/MonitorInputSwitcher"
        )
    ]
)
