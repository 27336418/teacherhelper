// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScheduleBar",
    platforms: [.macOS(.v12)],   // 覆盖 Intel(2015+) 与 M1/M2/M3/M4 的 macOS 12+
    targets: [
        .executableTarget(
            name: "ScheduleBar",
            path: "Sources/ScheduleBar"
        )
    ]
)
