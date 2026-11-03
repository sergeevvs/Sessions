// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pomodoro",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PomodoroCore", targets: ["PomodoroCore"]),
        .executable(name: "Pomodoro", targets: ["PomodoroApp"])
    ],
    targets: [
        .target(name: "PomodoroCore"),
        .executableTarget(name: "PomodoroApp", dependencies: ["PomodoroCore"]),
        .testTarget(name: "PomodoroCoreTests", dependencies: ["PomodoroCore"]),
        .testTarget(name: "PomodoroAppTests", dependencies: ["PomodoroApp"])
    ]
)
